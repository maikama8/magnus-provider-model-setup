#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2026-07-03-1"
MAGNUS_ROOT="/var/www/html/mbilling"
ASTERISK_DIR="/etc/asterisk"
PUBLIC_IP=""
LOCAL_NET=""
PUBLIC_IP_SET=0
LOCAL_NET_SET=0
FAIL2BAN_IGNORE=""
SKIP_RELOAD=0
DRY_RUN=0

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

print_banner() {
  cat <<'EOF'
======================= BY ZARACHTECH.COM.NG =======================

 ______                         _     _            _
|___  /                        | |   | |          | |
   / / __ _ _ __ __ _  ___ ___ | |__ | |_ ___  ___| |__
  / / / _` | '__/ _` |/ __/ _ \| '_ \| __/ _ \/ __| '_ \
 / /_| (_| | | | (_| | (_| (_) | | | | ||  __/ (__| | | |
/_____\__,_|_|  \__,_|\___\___/|_| |_|\__\___|\___|_| |_|

==================== MAGNUSBILLING PROVIDER SETUP ==================
EOF
  printf 'Setup script version: %s\n\n' "$SCRIPT_VERSION"
}

usage() {
  cat <<'EOF'
Usage:
  bash setup.sh [options]

Options:
  --magnus-root PATH     MagnusBilling path. Default: /var/www/html/mbilling
  --asterisk-dir PATH    Asterisk config path. Default: /etc/asterisk
  --public-ip IP         Public IP for Asterisk external media/signaling.
  --local-net CIDR       Local/private network CIDR, for example YOUR_PRIVATE_NETWORK_CIDR.
  --fail2ban-ignore LIST IPs/CIDR ranges to add to fail2ban ignoreip.
  --skip-reload          Do not run Asterisk reload commands.
  --dry-run              Show checks but do not edit files.
  -h, --help             Show this help.

Examples:
  bash setup.sh
  bash setup.sh --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR
  bash setup.sh --fail2ban-ignore "YOUR_OFFICE_IP YOUR_VPN_CIDR"
  bash setup.sh --skip-reload

What this script applies:
  - Backs up important Magnus/Asterisk files.
  - Adds MB_ACC generation to Magnus SIP users if missing.
  - Adds optional "SIP user: Create automatically" checkbox to Clients -> Users -> Add.
  - Defaults manually-created SIP users' NAT Qualify setting to yes.
  - Adds safe public DID catch-all context and AGI guard.
  - Adds/updates anonymous PJSIP endpoint for DID catch-all.
  - Ensures pjsip.conf includes pjsip_custom.conf.
  - Sets Magnus-side PJSIP/RTP NAT audio settings when --public-ip is provided.
  - Optionally adds trusted IPs/CIDR ranges to fail2ban ignoreip.
  - Reloads Asterisk and prints verification commands/results.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --magnus-root)
      MAGNUS_ROOT="${2:-}"
      shift 2
      ;;
    --asterisk-dir)
      ASTERISK_DIR="${2:-}"
      shift 2
      ;;
    --public-ip)
      PUBLIC_IP="${2:-}"
      PUBLIC_IP_SET=1
      shift 2
      ;;
    --local-net)
      LOCAL_NET="${2:-}"
      LOCAL_NET_SET=1
      shift 2
      ;;
    --fail2ban-ignore)
      FAIL2BAN_IGNORE="${2:-}"
      shift 2
      ;;
    --skip-reload)
      SKIP_RELOAD=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

print_banner

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root."
[[ -d "$MAGNUS_ROOT" ]] || die "Magnus root not found: $MAGNUS_ROOT"
[[ -d "$ASTERISK_DIR" ]] || die "Asterisk config directory not found: $ASTERISK_DIR"
[[ -f "$MAGNUS_ROOT/protected/components/AsteriskAccess.php" ]] || die "AsteriskAccess.php not found."
[[ -f "$MAGNUS_ROOT/protected/controllers/UserController.php" ]] || die "UserController.php not found."
[[ -f "$MAGNUS_ROOT/protected/controllers/SipController.php" ]] || die "SipController.php not found."
[[ -f "$ASTERISK_DIR/extensions.conf" ]] || die "extensions.conf not found."
[[ -f "$ASTERISK_DIR/pjsip.conf" ]] || die "pjsip.conf not found."

ensure_optional_asterisk_file() {
  local file="$1"
  local name="$2"

  if [[ -e "$file" && ! -f "$file" ]]; then
    die "$name exists but is not a regular file: $file"
  fi

  if [[ -f "$file" ]]; then
    return
  fi

  log "$name not found; creating $file."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$(dirname "$file")"
    touch "$file"
    local owner
    owner="$(stat -c '%U:%G' "$ASTERISK_DIR/pjsip.conf" 2>/dev/null || true)"
    if [[ -n "$owner" ]]; then
      chown "$owner" "$file" 2>/dev/null || true
    fi
  fi
}

ensure_optional_asterisk_file "$ASTERISK_DIR/pjsip_custom.conf" "pjsip_custom.conf"
ensure_optional_asterisk_file "$ASTERISK_DIR/rtp.conf" "rtp.conf"

is_interactive() {
  [[ -t 0 ]]
}

is_skip_value() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ -z "$value" || "$value" == "skip" || "$value" == "none" || "$value" == "no" || "$value" == "n/a" ]]
}

is_use_detected_value() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$value" == "use detected" || "$value" == "detected" || "$value" == "default" ]]
}

is_ipv4() {
  local ip="$1"
  local o1 o2 o3 o4
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local cidr="$1"
  local ip mask
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || return 1
  ip="${cidr%/*}"
  mask="${cidr#*/}"
  is_ipv4 "$ip" || return 1
  [[ "$mask" -ge 0 && "$mask" -le 32 ]]
}

detect_public_ip() {
  if command -v curl >/dev/null 2>&1; then
    curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true
  fi
}

detect_local_net() {
  if command -v ip >/dev/null 2>&1; then
    ip -o -f inet addr show scope global 2>/dev/null | awk '{print $4}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true
  fi
}

prompt_optional_value() {
  local label="$1"
  local detected="$2"
  local answer=""

  if ! is_interactive; then
    printf '%s' "$detected"
    return
  fi

  if [[ -n "$detected" ]]; then
    printf '%s [detected: %s, Enter=use detected, type skip to skip]: ' "$label" "$detected" >&2
  else
    printf '%s [Enter=skip]: ' "$label" >&2
  fi

  read -r answer || answer=""
  if is_use_detected_value "$answer" && [[ -n "$detected" ]]; then
    printf '%s' "$detected"
    return
  fi
  if [[ -z "$answer" && -n "$detected" ]]; then
    printf '%s' "$detected"
    return
  fi
  if is_skip_value "$answer"; then
    printf ''
    return
  fi
  printf '%s' "$answer"
}

prompt_fail2ban_ignore() {
  local answer=""

  if ! is_interactive; then
    printf ''
    return
  fi

  printf 'Fail2Ban ignore IPs/CIDR ranges [comma/space separated, Enter=skip]: ' >&2
  read -r answer || answer=""
  if is_skip_value "$answer"; then
    printf ''
    return
  fi
  printf '%s' "$answer"
}

DETECTED_PUBLIC_IP=""
DETECTED_LOCAL_NET=""

if [[ "$PUBLIC_IP_SET" -eq 0 ]]; then
  DETECTED_PUBLIC_IP="$(detect_public_ip)"
  PUBLIC_IP="$(prompt_optional_value "Public IP for Asterisk NAT/audio" "$DETECTED_PUBLIC_IP")"
fi

if [[ "$LOCAL_NET_SET" -eq 0 ]]; then
  DETECTED_LOCAL_NET="$(detect_local_net)"
  LOCAL_NET="$(prompt_optional_value "Local/private network CIDR" "$DETECTED_LOCAL_NET")"
fi

if [[ -z "$FAIL2BAN_IGNORE" ]]; then
  FAIL2BAN_IGNORE="$(prompt_fail2ban_ignore)"
fi

if [[ -n "$PUBLIC_IP" ]] && ! is_ipv4 "$PUBLIC_IP"; then
  die "Invalid public IP value: $PUBLIC_IP"
fi

if [[ -n "$LOCAL_NET" ]] && ! is_ipv4_cidr "$LOCAL_NET"; then
  die "Invalid local/private network CIDR value: $LOCAL_NET"
fi

TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="/root/magnus-provider-model-backup-$TS"

run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

backup_file() {
  local src="$1"
  if [[ -e "$src" ]]; then
    local rel="${src#/}"
    local dst="$BACKUP_DIR/files/$rel"
    run mkdir -p "$(dirname "$dst")"
    run cp -a "$src" "$dst"
  fi
}

log "Magnus root: $MAGNUS_ROOT"
log "Asterisk dir: $ASTERISK_DIR"
log "Public IP: ${PUBLIC_IP:-not set}"
log "Local net: ${LOCAL_NET:-not set}"
log "Fail2Ban ignore list additions: ${FAIL2BAN_IGNORE:-not set}"
log "Backup dir: $BACKUP_DIR"

run mkdir -p "$BACKUP_DIR/files"
backup_file "$MAGNUS_ROOT/protected/components/AsteriskAccess.php"
backup_file "$MAGNUS_ROOT/protected/controllers/UserController.php"
backup_file "$MAGNUS_ROOT/protected/controllers/SipController.php"
while IFS= read -r -d '' app_js; do
  backup_file "$app_js"
done < <(find "$MAGNUS_ROOT" -maxdepth 2 -name app.js -type f -print0)
backup_file "$ASTERISK_DIR/pjsip_custom.conf"
backup_file "$ASTERISK_DIR/pjsip_magnus.conf"
backup_file "$ASTERISK_DIR/extensions.conf"
backup_file "$ASTERISK_DIR/pjsip.conf"
backup_file "$ASTERISK_DIR/rtp.conf"
backup_file "$ASTERISK_DIR/extensions_public_did.conf"
backup_file "$MAGNUS_ROOT/resources/asterisk/public_did_guard.php"
backup_file "/etc/fail2ban/jail.local"
backup_file "/etc/fail2ban/jail.d/magnus-provider-model-ignoreip.local"

if [[ -f "$ASTERISK_DIR/res_config_mysql.conf" ]] && command -v mysqldump >/dev/null 2>&1; then
  log "Creating best-effort database backup of core Magnus tables."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    DBHOST="$(awk -F= '/^[[:space:]]*dbhost[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$ASTERISK_DIR/res_config_mysql.conf" | tail -1)"
    DBNAME="$(awk -F= '/^[[:space:]]*dbname[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$ASTERISK_DIR/res_config_mysql.conf" | tail -1)"
    DBUSER="$(awk -F= '/^[[:space:]]*dbuser[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2}' "$ASTERISK_DIR/res_config_mysql.conf" | tail -1)"
    DBPASS="$(awk -F= '/^[[:space:]]*dbpass[[:space:]]*=/{sub(/^[[:space:]]*/,"",$2); sub(/[[:space:]]*$/,"",$2); print $2}' "$ASTERISK_DIR/res_config_mysql.conf" | tail -1)"
    if [[ -n "${DBHOST:-}" && -n "${DBNAME:-}" && -n "${DBUSER:-}" ]]; then
      mysqldump -h"$DBHOST" -u"$DBUSER" -p"$DBPASS" "$DBNAME" \
        pkg_trunk pkg_trunk_group pkg_trunk_group_trunk pkg_sip pkg_did pkg_did_destination pkg_user pkg_rate pkg_provider \
        > "$BACKUP_DIR/magnus-core-tables.sql" 2>"$BACKUP_DIR/mysqldump.err" || log "Database backup failed. See $BACKUP_DIR/mysqldump.err"
    else
      log "Could not parse DB settings from res_config_mysql.conf; skipping DB backup."
    fi
  fi
else
  log "Skipping DB backup because mysqldump or res_config_mysql.conf is unavailable."
fi

patch_mb_acc() {
  local file="$MAGNUS_ROOT/protected/components/AsteriskAccess.php"

  if grep -q 'set_var=MB_ACC' "$file"; then
    log "MB_ACC generation already exists in AsteriskAccess.php."
    return
  fi

  log "Adding MB_ACC generation to AsteriskAccess.php."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$file" <<'PHP'
<?php
$file = $argv[1];
$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Cannot read $file\n");
    exit(1);
}

if (strpos($src, 'set_var=MB_ACC') !== false) {
    exit(0);
}

$pattern = '/^([ \t]*\$line\s*\.=\s*"transport=transport-udp\\\\n";\R)/m';
$count = 0;
$src = preg_replace_callback($pattern, static function ($m) {
    preg_match('/^([ \t]*)/', $m[1], $indent);
    $i = $indent[1] ?? '';
    return $m[1]
        . "\n"
        . $i . "// accountcode -> set_var\n"
        . $i . '$line .= "set_var=MB_ACC=" . $sip->idUser->username . "\n";' . "\n";
}, $src, 1, $count);

if ($count < 1) {
    fwrite(STDERR, "Could not find transport=transport-udp anchor in $file\n");
    exit(1);
}

if (file_put_contents($file, $src) === false) {
    fwrite(STDERR, "Cannot write $file\n");
    exit(1);
}
PHP
}

patch_user_create_sip_toggle() {
  local controller="$MAGNUS_ROOT/protected/controllers/UserController.php"
  log "Adding optional SIP auto-create toggle to user creation."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$controller" "$MAGNUS_ROOT" <<'TOGGLEPHP'
<?php
$controller = $argv[1];
$root = rtrim($argv[2], '/');
$src = file_get_contents($controller);
if ($src === false) {
    fwrite(STDERR, "Cannot read $controller\n");
    exit(1);
}

if (strpos($src, 'function getDefaultClientGroupId') === false) {
    $old = <<<'OLD'
    public function beforeSave($values)
    {
OLD;
    $new = <<<'NEW'
    protected function getDefaultClientGroupId()
    {
        $modelGroupUser = GroupUser::model()->find('id_user_type = 3');
        return isset($modelGroupUser->id) ? $modelGroupUser->id : 3;
    }

    public function beforeSave($values)
    {
NEW;
    $src = str_replace($old, $new, $src, $count);
    if ($count < 1) {
        fwrite(STDERR, "Could not find beforeSave insert point in $controller\n");
        exit(1);
    }
}

if (strpos($src, "\$values['id_group'] = \$this->getDefaultClientGroupId();") === false) {
    $old = <<<'OLD'
        if ($this->isNewRecord) {

            $groupType = GroupUser::model()->find(
OLD;
    $new = <<<'NEW'
        if ($this->isNewRecord) {
            if (empty($values['id_group']) && Yii::app()->session['isAdmin'] == true) {
                $values['id_group'] = $this->getDefaultClientGroupId();
            }

            $groupType = GroupUser::model()->find(
NEW;
    $src = str_replace($old, $new, $src, $count);
    if ($count < 1) {
        fwrite(STDERR, "Could not find new-record group insert point in $controller\n");
        exit(1);
    }
}

if (strpos($src, 'function shouldCreateSipUser') === false) {
    $old = <<<'OLD'
    public function afterSave($model, $values)
    {

        if ($model->idGroup->idUserType->id == 3) {
OLD;
    $new = <<<'NEW'
    protected function shouldCreateSipUser($values)
    {
        return isset($values['create_sip_user']) && (int) $values['create_sip_user'] === 1;
    }

    public function afterSave($model, $values)
    {
        $shouldManageSipUser = ! $this->isNewRecord || $this->shouldCreateSipUser($values);

        if ($model->idGroup->idUserType->id == 3 && $shouldManageSipUser) {
NEW;
    $src = str_replace($old, $new, $src, $count);
    if ($count < 1) {
        fwrite(STDERR, "Could not find afterSave insert point in $controller\n");
        exit(1);
    }
}

if (strpos($src, '$createSipUser = $this->shouldCreateSipUser($values);') === false) {
    $old = <<<'OLD'
        if ($modelGroupUser->id_user_type != 3) {
            echo json_encode([
                $this->nameSuccess => false,
                $this->nameMsg     => 'Only allowed create user. you try create admin or agent',
            ]);
            exit;
        }
        for ($i = 0; $i < $values['totalToCreate']; $i++) {
OLD;
    $new = <<<'NEW'
        if ($modelGroupUser->id_user_type != 3) {
            echo json_encode([
                $this->nameSuccess => false,
                $this->nameMsg     => 'Only allowed create user. you try create admin or agent',
            ]);
            exit;
        }

        $createSipUser = $this->shouldCreateSipUser($values);
        $sipPeersChanged = false;

        for ($i = 0; $i < $values['totalToCreate']; $i++) {
NEW;
    $src = str_replace($old, $new, $src, $count);
    if ($count < 1) {
        fwrite(STDERR, "Could not find bulk create insert point in $controller\n");
        exit(1);
    }
}

if (strpos($src, 'if ($createSipUser && $modelUser->idGroup->idUserType->id == 3)') === false) {
    $src = str_replace(
        "            if (\$modelUser->idGroup->idUserType->id == 3) {\n                \$modelSip              = new Sip();\n",
        "            if (\$createSipUser && \$modelUser->idGroup->idUserType->id == 3) {\n                \$modelSip              = new Sip();\n",
        $src,
        $count
    );
    if ($count < 1) {
        fwrite(STDERR, "Could not patch bulk SIP create guard in $controller\n");
        exit(1);
    }

    $src = str_replace(
        "                \$modelSip->secret      = \$modelUser->password;\n                \$modelSip->save();\n            }\n",
        "                \$modelSip->secret      = \$modelUser->password;\n                \$modelSip->save();\n                \$sipPeersChanged = true;\n            }\n",
        $src,
        $count
    );
    if ($count < 1) {
        fwrite(STDERR, "Could not patch bulk SIP save marker in $controller\n");
        exit(1);
    }
}

if (strpos($src, 'if ($sipPeersChanged) {') === false) {
    $old = "        AsteriskAccess::instance()->generateSipPeers();\n\n        echo json_encode([\n";
    $new = "        if (\$sipPeersChanged) {\n            AsteriskAccess::instance()->generateSipPeers();\n        }\n\n        echo json_encode([\n";
    $pos = strrpos($src, $old);
    if ($pos === false) {
        fwrite(STDERR, "Could not find bulk generateSipPeers call in $controller\n");
        exit(1);
    }
    $src = substr($src, 0, $pos) . $new . substr($src, $pos + strlen($old));
}

if (file_put_contents($controller, $src) === false) {
    fwrite(STDERR, "Cannot write $controller\n");
    exit(1);
}

$passwordField = '{name:"password",fieldLabel:t("Password"),minLength:6,hidden:App.user.isClient,allowBlank:App.user.isClient},';
$checkbox = '{xtype:"checkboxfield",name:"create_sip_user",fieldLabel:t("SIP user"),boxLabel:t("Create automatically"),checked:false,inputValue:1,uncheckedValue:0,hidden:App.user.isClient,allowBlank:true},';
$oldCheckedCheckbox = '{xtype:"checkboxfield",name:"create_sip_user",fieldLabel:t("SIP user"),boxLabel:t("Create automatically"),checked:true,inputValue:1,uncheckedValue:0,hidden:App.user.isClient,allowBlank:true},';
$oldLabelCheckbox = '{xtype:"checkboxfield",name:"create_sip_user",fieldLabel:t("Create SIP user"),boxLabel:t("Automatically create SIP user"),checked:true,inputValue:1,uncheckedValue:0,hidden:App.user.isClient,allowBlank:true},';
$modernGroupPlain = '{xtype:"groupusercombo",name:"id_group",fieldLabel:t("Group"),allowBlank:!App.user.isAdmin,hidden:!App.user.isAdmin}';
$modernGroupDefault = '{xtype:"groupusercombo",name:"id_group",fieldLabel:t("Group"),value:3,allowBlank:!App.user.isAdmin,hidden:!App.user.isAdmin}';
$classicGroupPlain = '{xtype:"groupusercombo",allowBlank:!App.user.isAdmin,hidden:!App.user.isAdmin}';
$classicGroupDefault = '{xtype:"groupusercombo",value:3,allowBlank:!App.user.isAdmin,hidden:!App.user.isAdmin}';
$patched = 0;
foreach (glob($root . '/*/app.js') ?: [] as $app) {
    $appSrc = file_get_contents($app);
    if ($appSrc === false || strpos($appSrc, 'MBilling.view.user.Form') === false) {
        continue;
    }

    $updated = str_replace([$checkbox, $oldCheckedCheckbox, $oldLabelCheckbox], '', $appSrc);
    $updated = str_replace($modernGroupDefault, $modernGroupPlain, $updated);
    $updated = str_replace($classicGroupDefault, $classicGroupPlain, $updated);

    if (strpos($updated, $passwordField) === false) {
        continue;
    }
    $updated = str_replace($passwordField, $passwordField . $checkbox, $updated, $count);

    $marker = 'name:"create_sip_user"';
    $idx = strpos($updated, $marker);
    if ($idx !== false) {
        $window = substr($updated, $idx, 2500);
        if (strpos($window, $modernGroupPlain) !== false) {
            $groupPos = strpos($updated, $modernGroupPlain, $idx);
            $updated = substr($updated, 0, $groupPos) . $modernGroupDefault . substr($updated, $groupPos + strlen($modernGroupPlain));
        } elseif (strpos($window, $classicGroupPlain) !== false) {
            $groupPos = strpos($updated, $classicGroupPlain, $idx);
            $updated = substr($updated, 0, $groupPos) . $classicGroupDefault . substr($updated, $groupPos + strlen($classicGroupPlain));
        }
    }

    if ($updated === $appSrc) {
        continue;
    }
    if (file_put_contents($app, $updated) === false) {
        fwrite(STDERR, "Could not patch $app\n");
        exit(1);
    }
    $patched++;
}

echo "Patched theme app.js files: $patched\n";
TOGGLEPHP

  php -l "$controller" >/dev/null
}

patch_manual_sip_qualify_default() {
  local controller="$MAGNUS_ROOT/protected/controllers/SipController.php"

  log "Setting manual SIP user creation default Qualify to yes."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$controller" "$MAGNUS_ROOT" <<'SIPQUALIFYPHP'
<?php
$controller = $argv[1];
$root = rtrim($argv[2], '/');

$src = file_get_contents($controller);
if ($src === false) {
    fwrite(STDERR, "Cannot read $controller\n");
    exit(1);
}

if (strpos($src, "\$values['qualify']   = 'yes';") === false) {
    $pattern = '/([ \t]*\$values\[\x27regseconds\x27\][ \t]*=[ \t]*1;[ \t]*\R[ \t]*\$values\[\x27context\x27\][ \t]*=[ \t]*\x27billing\x27;[ \t]*\R)([ \t]*\$values\[\x27regexten\x27\][ \t]*=[ \t]*\$values\[\x27name\x27\];)/';
    $replacement = <<<'NEW'
${1}            $values['qualify']   = 'yes';
$2
NEW;
    $src = preg_replace($pattern, $replacement, $src, 1, $count);
    if ($src === null) {
        fwrite(STDERR, "Regex failed while patching $controller\n");
        exit(1);
    }
    if ($count < 1) {
        fwrite(STDERR, "Could not find manual SIP create defaults in $controller\n");
        exit(1);
    }
}

if (file_put_contents($controller, $src) === false) {
    fwrite(STDERR, "Cannot write $controller\n");
    exit(1);
}

$patched = 0;
foreach (glob($root . '/*/app.js') ?: [] as $app) {
    $appSrc = file_get_contents($app);
    if ($appSrc === false || strpos($appSrc, 'MBilling.view.sip.Form') === false) {
        continue;
    }

    $updated = preg_replace(
        '/(\{xtype:"yesnostringcombo",name:"qualify",fieldLabel:t\("Qualify"\),value:)"no"(,allowBlank:!App\.user\.isAdmin\})/',
        '$1"yes"$2',
        $appSrc,
        -1,
        $count
    );

    if ($updated === null) {
        fwrite(STDERR, "Regex failed while patching $app\n");
        exit(1);
    }

    if ($count < 1 || $updated === $appSrc) {
        continue;
    }

    if (file_put_contents($app, $updated) === false) {
        fwrite(STDERR, "Could not patch $app\n");
        exit(1);
    }
    $patched++;
}

echo "Patched SIP qualify defaults in theme app.js files: $patched\n";
SIPQUALIFYPHP

  php -l "$controller" >/dev/null
}

write_did_guard_files() {
  local ext_file="$ASTERISK_DIR/extensions_public_did.conf"
  local agi_dir="$MAGNUS_ROOT/resources/asterisk"
  local agi_file="$agi_dir/public_did_guard.php"

  log "Writing DID catch-all dialplan: $ext_file"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    cat > "$ext_file" <<'EOF'
[public-did-inbound]
exten => _+X.,1,NoOp(Public DID catch-all guard for ${EXTEN} from ${CALLERID(all)})
 same => n,AGI(/var/www/html/mbilling/resources/asterisk/public_did_guard.php)
 same => n,GotoIf($["${PUBLIC_DID_OK}"="1"]?billing,${EXTEN},1)
 same => n,Hangup(21)

exten => _[*0-9].,1,NoOp(Public DID catch-all guard for ${EXTEN} from ${CALLERID(all)})
 same => n,AGI(/var/www/html/mbilling/resources/asterisk/public_did_guard.php)
 same => n,GotoIf($["${PUBLIC_DID_OK}"="1"]?billing,${EXTEN},1)
 same => n,Hangup(21)

exten => s,1,Hangup(21)
exten => i,1,Hangup(21)
exten => h,1,Hangup()
EOF
  fi

  log "Writing DID guard AGI: $agi_file"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$agi_dir"
    cat > "$agi_file" <<'EOF'
#!/usr/bin/php -q
<?php
set_time_limit(5);

$agi = [];
while (($line = fgets(STDIN)) !== false) {
    $line = trim($line);
    if ($line === '') {
        break;
    }
    $parts = explode(':', $line, 2);
    if (count($parts) === 2) {
        $agi[trim($parts[0])] = trim($parts[1]);
    }
}

function agi_set_variable($name, $value)
{
    echo 'SET VARIABLE ' . $name . ' "' . $value . '"' . "\n";
    flush();
}

function normalize_did_candidates($value)
{
    $value = preg_replace('/[^0-9+]/', '', (string) $value);
    $candidates = [];

    if ($value !== '') {
        $candidates[] = $value;
        if ($value[0] === '+') {
            $candidates[] = substr($value, 1);
        } else {
            $candidates[] = '+' . $value;
        }
    }

    return array_values(array_unique(array_filter($candidates, static function ($candidate) {
        return $candidate !== '' && $candidate !== '+';
    })));
}

$extension = $agi['agi_extension'] ?? ($agi['agi_dnid'] ?? '');
$candidates = normalize_did_candidates($extension);
$allowed = false;

try {
    if ($candidates) {
        $config = parse_ini_file('/etc/asterisk/res_config_mysql.conf');
        if (!$config || empty($config['dbhost']) || empty($config['dbname']) || empty($config['dbuser'])) {
            throw new RuntimeException('Missing database configuration');
        }

        $pdo = new PDO(
            'mysql:host=' . $config['dbhost'] . ';dbname=' . $config['dbname'] . ';charset=utf8',
            $config['dbuser'],
            $config['dbpass'] ?? '',
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_TIMEOUT => 2,
            ]
        );

        $placeholders = implode(',', array_fill(0, count($candidates), '?'));
        $sql = 'SELECT id FROM pkg_did WHERE activated = 1 AND did IN (' . $placeholders . ') LIMIT 1';
        $stmt = $pdo->prepare($sql);
        $stmt->execute($candidates);
        $allowed = (bool) $stmt->fetchColumn();
    }
} catch (Throwable $e) {
    openlog('public_did_guard', LOG_PID, LOG_LOCAL0);
    syslog(LOG_ERR, 'DID guard database check failed: ' . $e->getMessage());
    closelog();
    $allowed = false;
}

if (!$allowed) {
    openlog('public_did_guard', LOG_PID, LOG_LOCAL0);
    syslog(LOG_NOTICE, 'Rejected public inbound DID attempt for extension=' . $extension);
    closelog();
}

agi_set_variable('PUBLIC_DID_OK', $allowed ? '1' : '0');
EOF
    chmod 755 "$agi_file"
    owner="$(stat -c '%U:%G' "$agi_dir" 2>/dev/null || true)"
    if [[ -n "$owner" ]]; then
      chown "$owner" "$agi_file" 2>/dev/null || true
    fi
  fi
}

ensure_extensions_include() {
  local file="$ASTERISK_DIR/extensions.conf"
  if grep -Eq '^[[:space:]]*#include[[:space:]]+extensions_public_did\.conf' "$file"; then
    log "extensions.conf already includes extensions_public_did.conf."
    return
  fi

  log "Adding #include extensions_public_did.conf to extensions.conf."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    printf '\n#include extensions_public_did.conf\n' >> "$file"
  fi
}

set_provider_trunks_context_billing() {
  log "Setting provider trunk context to billing."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php <<'PHP'
<?php
$config = parse_ini_file('/etc/asterisk/res_config_mysql.conf');
if (!$config || empty($config['dbhost']) || empty($config['dbname']) || empty($config['dbuser'])) {
    fwrite(STDERR, "Could not parse DB settings; skipping trunk context update\n");
    exit(0);
}

$pdo = new PDO(
    'mysql:host=' . $config['dbhost'] . ';dbname=' . $config['dbname'] . ';charset=utf8',
    $config['dbuser'],
    $config['dbpass'] ?? '',
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$pdo->exec("UPDATE pkg_trunk SET context = 'billing' WHERE context IS NULL OR context <> 'billing'");
PHP

  if [[ -f "$ASTERISK_DIR/pjsip_magnus.conf" ]]; then
    sed -i \
      -e 's/context = public-did-inbound/context = billing/g' \
      -e 's/context = outbound-only/context = billing/g' \
      "$ASTERISK_DIR/pjsip_magnus.conf"
  fi
}

patch_pjsip_custom() {
  local file="$ASTERISK_DIR/pjsip_custom.conf"
  log "Adding/updating global endpoint order and anonymous DID endpoint in pjsip_custom.conf."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$file" <<'PHP'
<?php
$file = $argv[1];
$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Cannot read $file\n");
    exit(1);
}

function ensure_key_in_section(string $src, string $section, string $key, string $value): string
{
    $sectionPattern = '/^\[' . preg_quote($section, '/') . '\]\R(?P<body>.*?)(?=^\[|\z)/ms';
    if (!preg_match($sectionPattern, $src)) {
        return rtrim($src) . "\n\n[$section]\n$key=$value\n";
    }

    return preg_replace_callback($sectionPattern, static function ($m) use ($key, $value) {
        $block = $m[0];
        if (preg_match('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*=/m', $block)) {
            return preg_replace('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*=.*$/m', "$key=$value", $block);
        }
        return preg_replace('/^(\[[^\]]+\]\R)/', "$1$key=$value\n", $block, 1);
    }, $src, 1);
}

function replace_section(string $src, string $section, string $body): string
{
    $new = "[$section]\n" . rtrim($body) . "\n\n";
    $sectionPattern = '/^\[' . preg_quote($section, '/') . '\]\R.*?(?=^\[|\z)/ms';
    if (preg_match($sectionPattern, $src)) {
        return preg_replace($sectionPattern, $new, $src, 1);
    }
    return rtrim($src) . "\n\n" . $new;
}

$src = ensure_key_in_section($src, 'global', 'type', 'global');
$src = ensure_key_in_section($src, 'global', 'endpoint_identifier_order', 'ip,auth_username,username,anonymous');
$anonymous = <<<'EOF'
type=endpoint
context=public-did-inbound
disallow=all
allow=ulaw,alaw,g729,gsm
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
allow_subscribe=no
EOF;
$src = replace_section($src, 'anonymous', $anonymous);

if (file_put_contents($file, $src) === false) {
    fwrite(STDERR, "Cannot write $file\n");
    exit(1);
}
PHP
}

ensure_pjsip_custom_include() {
  local file="$ASTERISK_DIR/pjsip.conf"
  log "Ensuring pjsip.conf includes pjsip_custom.conf."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$file" <<'PHP'
<?php
$file = $argv[1];
$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Cannot read $file\n");
    exit(1);
}

if (preg_match('/^[ \t]*#include[ \t]+pjsip_custom\.conf[ \t]*$/m', $src)) {
    exit(0);
}

$include = "#include pjsip_custom.conf\n";
if (preg_match('/^[ \t]*#include[ \t]+pjsip_magnus_user\.conf[ \t]*\R/m', $src)) {
    $src = preg_replace('/(^[ \t]*#include[ \t]+pjsip_magnus_user\.conf[ \t]*\R)/m', "$1$include", $src, 1);
} elseif (preg_match('/^[ \t]*#include[ \t]+pjsip_magnus\.conf[ \t]*\R/m', $src)) {
    $src = preg_replace('/(^[ \t]*#include[ \t]+pjsip_magnus\.conf[ \t]*\R)/m', "$1$include", $src, 1);
} else {
    $src = rtrim($src) . "\n\n" . $include;
}

if (file_put_contents($file, $src) === false) {
    fwrite(STDERR, "Cannot write $file\n");
    exit(1);
}
PHP
}

patch_pjsip_audio() {
  if [[ -z "$PUBLIC_IP" ]]; then
    log "No public IP available; skipping pjsip.conf external media/signaling update."
    log "Run again with --public-ip PUBLIC_IP and optional --local-net CIDR to apply NAT audio settings."
    return
  fi

  log "Setting Magnus-side PJSIP audio/NAT values in pjsip.conf."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php /dev/stdin "$ASTERISK_DIR/pjsip.conf" "$PUBLIC_IP" "$LOCAL_NET" <<'PHP'
<?php
$file = $argv[1];
$publicIp = $argv[2];
$localNet = $argv[3] ?? '';
$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Cannot read $file\n");
    exit(1);
}

function ensure_key_in_section_body(string $body, string $key, string $value): string
{
    if (preg_match('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*=/m', $body)) {
        return preg_replace('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*=.*$/m', "$key = $value", $body);
    }
    return rtrim($body) . "\n$key = $value\n";
}

$src = preg_replace('/^[ \t]*(external_signaling_address|external_media_address|local_net)[ \t]*=.*\R?/m', '', $src);

$pattern = '/^\[transport-udp\]\R(?P<body>.*?)(?=^#include|^\[|\z)/ms';
if (!preg_match($pattern, $src)) {
    fwrite(STDERR, "Cannot find [transport-udp] section in $file\n");
    exit(1);
}

$src = preg_replace_callback($pattern, static function ($m) use ($publicIp, $localNet) {
    $body = $m['body'];
    $body = ensure_key_in_section_body($body, 'external_signaling_address', $publicIp);
    $body = ensure_key_in_section_body($body, 'external_media_address', $publicIp);
    if ($localNet !== '') {
        $body = ensure_key_in_section_body($body, 'local_net', $localNet);
    }
    return "[transport-udp]\n" . rtrim($body) . "\n\n";
}, $src, 1);

if (file_put_contents($file, $src) === false) {
    fwrite(STDERR, "Cannot write $file\n");
    exit(1);
}
PHP
}

patch_rtp_conf() {
  local file="$ASTERISK_DIR/rtp.conf"
  log "Setting RTP range in rtp.conf."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  if grep -qE '^[[:space:]]*rtpstart[[:space:]]*=' "$file"; then
    sed -i 's/^[[:space:]]*rtpstart[[:space:]]*=.*/rtpstart=10000/' "$file"
  else
    printf '\nrtpstart=10000\n' >> "$file"
  fi

  if grep -qE '^[[:space:]]*rtpend[[:space:]]*=' "$file"; then
    sed -i 's/^[[:space:]]*rtpend[[:space:]]*=.*/rtpend=20000/' "$file"
  else
    printf 'rtpend=20000\n' >> "$file"
  fi
}

normalize_fail2ban_ignore_input() {
  local raw="${1//,/ }"
  local token
  local values=()

  for token in $raw; do
    if [[ ! "$token" =~ ^[A-Za-z0-9:._/-]+$ ]]; then
      die "Unsafe fail2ban ignore value: $token"
    fi
    values+=("$token")
  done

  if [[ "${#values[@]}" -eq 0 ]]; then
    return
  fi

  printf '%s\n' "${values[@]}" | awk '!seen[$0]++' | paste -sd' ' -
}

patch_fail2ban_ignore() {
  if [[ -z "$FAIL2BAN_IGNORE" ]]; then
    log "No fail2ban ignore IPs provided; leaving fail2ban unchanged."
    return
  fi

  local additions
  additions="$(normalize_fail2ban_ignore_input "$FAIL2BAN_IGNORE")"
  if [[ -z "$additions" ]]; then
    log "No valid fail2ban ignore IPs provided; leaving fail2ban unchanged."
    return
  fi

  if [[ ! -d /etc/fail2ban ]]; then
    log "fail2ban config directory not found; skipping ignoreip update."
    return
  fi

  local file="/etc/fail2ban/jail.d/magnus-provider-model-ignoreip.local"
  if [[ -f /etc/fail2ban/jail.local ]]; then
    file="/etc/fail2ban/jail.local"
  fi

  log "Adding fail2ban ignoreip entries to $file: $additions"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  mkdir -p "$(dirname "$file")"
  touch "$file"

  php /dev/stdin "$file" "$additions" <<'PHP'
<?php
$file = $argv[1];
$additions = preg_split('/\s+/', trim($argv[2] ?? ''), -1, PREG_SPLIT_NO_EMPTY);
$src = file_exists($file) ? file_get_contents($file) : '';
if ($src === false) {
    fwrite(STDERR, "Cannot read $file\n");
    exit(1);
}

function unique_values(array $values): array
{
    $seen = [];
    $out = [];
    foreach ($values as $value) {
        $value = trim($value);
        if ($value === '' || isset($seen[$value])) {
            continue;
        }
        $seen[$value] = true;
        $out[] = $value;
    }
    return $out;
}

$sectionPattern = '/^\[DEFAULT\]\R(?P<body>.*?)(?=^\[|\z)/ms';
if (!preg_match($sectionPattern, $src)) {
    $line = 'ignoreip = ' . implode(' ', unique_values($additions)) . "\n";
    $src = "[DEFAULT]\n" . $line . "\n" . ltrim($src);
} else {
    $src = preg_replace_callback($sectionPattern, static function ($m) use ($additions) {
        $block = $m[0];
        if (preg_match('/^[ \t]*ignoreip[ \t]*=[ \t]*(.*)$/m', $block, $ignoreMatch)) {
            $current = preg_split('/\s+/', trim($ignoreMatch[1]), -1, PREG_SPLIT_NO_EMPTY);
            $merged = unique_values(array_merge($current, $additions));
            return preg_replace('/^[ \t]*ignoreip[ \t]*=.*$/m', 'ignoreip = ' . implode(' ', $merged), $block, 1);
        }

        return preg_replace('/^(\[DEFAULT\]\R)/', '$1ignoreip = ' . implode(' ', unique_values($additions)) . "\n", $block, 1);
    }, $src, 1);
}

if (file_put_contents($file, $src) === false) {
    fwrite(STDERR, "Cannot write $file\n");
    exit(1);
}
PHP

  if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client reload || systemctl restart fail2ban || log "fail2ban reload/restart failed"
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart fail2ban || log "fail2ban restart failed"
  else
    log "fail2ban restart command not found; restart fail2ban manually."
  fi
}

patch_mb_acc
patch_user_create_sip_toggle
patch_manual_sip_qualify_default
write_did_guard_files
ensure_extensions_include
set_provider_trunks_context_billing
patch_pjsip_custom
ensure_pjsip_custom_include
patch_pjsip_audio
patch_rtp_conf
patch_fail2ban_ignore

if [[ "$SKIP_RELOAD" -eq 0 ]]; then
  log "Reloading Asterisk dialplan and PJSIP."
  if [[ "$DRY_RUN" -eq 0 ]]; then
    asterisk -rx "dialplan reload" || log "dialplan reload failed"
    asterisk -rx "pjsip reload" || log "pjsip reload failed"
  fi
else
  log "Skipping Asterisk reload because --skip-reload was provided."
fi

log "Verification output:"
if [[ "$DRY_RUN" -eq 0 ]]; then
  grep -n 'set_var=MB_ACC' "$MAGNUS_ROOT/protected/components/AsteriskAccess.php" || true
  grep -n 'extensions_public_did.conf' "$ASTERISK_DIR/extensions.conf" || true
  grep -n 'pjsip_custom.conf' "$ASTERISK_DIR/pjsip.conf" || true
  asterisk -rx "dialplan show public-did-inbound" || true
  asterisk -rx "pjsip show endpoint anonymous" || true
fi

cat <<EOF

Done.

Backup directory:
  $BACKUP_DIR

Next manual checks:
  1. Create/confirm customer PBXs as Clients -> SIP Users.
  2. Keep provider carriers under Routes -> Trunks.
  3. Confirm production firewall allows UDP 5060 and UDP 10000-20000.
  4. Make one outbound test call and check Reports -> CDR / CDR Failed.
  5. Make one inbound DID test call and confirm only active DIDs pass the guard.
EOF
