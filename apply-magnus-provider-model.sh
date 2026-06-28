#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
MAGNUS_ROOT="/var/www/html/mbilling"
ASTERISK_DIR="/etc/asterisk"
PUBLIC_IP=""
LOCAL_NET=""
SKIP_RELOAD=0
DRY_RUN=0

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  bash apply-magnus-provider-model.sh [options]

Options:
  --magnus-root PATH     MagnusBilling path. Default: /var/www/html/mbilling
  --asterisk-dir PATH    Asterisk config path. Default: /etc/asterisk
  --public-ip IP         Public IP for Asterisk external media/signaling.
  --local-net CIDR       Local/private network CIDR, for example YOUR_PRIVATE_NETWORK_CIDR.
  --skip-reload          Do not run Asterisk reload commands.
  --dry-run              Show checks but do not edit files.
  -h, --help             Show this help.

Examples:
  bash apply-magnus-provider-model.sh --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR
  bash apply-magnus-provider-model.sh --skip-reload

What this script applies:
  - Backs up important Magnus/Asterisk files.
  - Adds MB_ACC generation to Magnus SIP users if missing.
  - Adds optional "SIP user: Create automatically" checkbox to Clients -> Users -> Add.
  - Adds safe public DID catch-all context and AGI guard.
  - Adds/updates anonymous PJSIP endpoint for DID catch-all.
  - Sets Magnus-side PJSIP/RTP NAT audio settings when --public-ip is provided.
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
      shift 2
      ;;
    --local-net)
      LOCAL_NET="${2:-}"
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

[[ "$(id -u)" -eq 0 ]] || die "Run this script as root."
[[ -d "$MAGNUS_ROOT" ]] || die "Magnus root not found: $MAGNUS_ROOT"
[[ -d "$ASTERISK_DIR" ]] || die "Asterisk config directory not found: $ASTERISK_DIR"
[[ -f "$MAGNUS_ROOT/protected/components/AsteriskAccess.php" ]] || die "AsteriskAccess.php not found."
[[ -f "$MAGNUS_ROOT/protected/controllers/UserController.php" ]] || die "UserController.php not found."
[[ -f "$ASTERISK_DIR/pjsip_custom.conf" ]] || die "pjsip_custom.conf not found."
[[ -f "$ASTERISK_DIR/extensions.conf" ]] || die "extensions.conf not found."
[[ -f "$ASTERISK_DIR/pjsip.conf" ]] || die "pjsip.conf not found."
[[ -f "$ASTERISK_DIR/rtp.conf" ]] || die "rtp.conf not found."

if [[ -z "$PUBLIC_IP" ]] && command -v curl >/dev/null 2>&1; then
  PUBLIC_IP="$(curl -4 -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)"
fi

if [[ -z "$LOCAL_NET" ]] && command -v ip >/dev/null 2>&1; then
  LOCAL_NET="$(ip -o -f inet addr show scope global 2>/dev/null | awk '{print $4}' | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)' | head -1 || true)"
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
log "Backup dir: $BACKUP_DIR"

run mkdir -p "$BACKUP_DIR/files"
backup_file "$MAGNUS_ROOT/protected/components/AsteriskAccess.php"
backup_file "$MAGNUS_ROOT/protected/controllers/UserController.php"
while IFS= read -r -d '' app_js; do
  backup_file "$app_js"
done < <(find "$MAGNUS_ROOT" -maxdepth 2 -name app.js -type f -print0)
backup_file "$ASTERISK_DIR/pjsip_custom.conf"
backup_file "$ASTERISK_DIR/extensions.conf"
backup_file "$ASTERISK_DIR/pjsip.conf"
backup_file "$ASTERISK_DIR/rtp.conf"
backup_file "$ASTERISK_DIR/extensions_public_did.conf"
backup_file "$ASTERISK_DIR/extensions_outbound_only.conf"
backup_file "$MAGNUS_ROOT/resources/asterisk/public_did_guard.php"

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

write_outbound_only_context() {
  local ext_file="$ASTERISK_DIR/extensions_outbound_only.conf"

  log "Writing outbound-only provider trunk reject context: $ext_file"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    cat > "$ext_file" <<'EOF'
[outbound-only]
exten => _.,1,NoOp(Reject inbound call received on outbound-only provider trunk: ${CHANNEL(endpoint)})
 same => n,Hangup(21)

exten => s,1,Hangup(21)
exten => i,1,Hangup(21)
exten => h,1,Hangup()
EOF
  fi
}

ensure_extensions_include() {
  local file="$ASTERISK_DIR/extensions.conf"
  local includes=(
    "extensions_public_did.conf"
    "extensions_outbound_only.conf"
  )
  local include

  for include in "${includes[@]}"; do
    if grep -Eq "^[[:space:]]*#include[[:space:]]+$include" "$file"; then
      log "extensions.conf already includes $include."
      continue
    fi

    log "Adding #include $include to extensions.conf."
    if [[ "$DRY_RUN" -eq 0 ]]; then
      printf '\n#include %s\n' "$include" >> "$file"
    fi
  done
}

protect_outbound_trunk_contexts() {
  log "Moving outbound provider trunks away from public-did-inbound when present."
  if [[ "$DRY_RUN" -eq 1 ]]; then
    return
  fi

  php <<'PHP'
<?php
$config = parse_ini_file('/etc/asterisk/res_config_mysql.conf');
if (!$config || empty($config['dbhost']) || empty($config['dbname']) || empty($config['dbuser'])) {
    fwrite(STDERR, "Could not parse DB settings; skipping trunk context protection\n");
    exit(0);
}

$pdo = new PDO(
    'mysql:host=' . $config['dbhost'] . ';dbname=' . $config['dbname'] . ';charset=utf8',
    $config['dbuser'],
    $config['dbpass'] ?? '',
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
);

$pdo->exec("UPDATE pkg_trunk SET context = 'outbound-only' WHERE context = 'public-did-inbound'");
PHP
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

$pattern = '/^\[transport-udp\]\R(?P<body>.*?)(?=^\[|\z)/ms';
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

patch_mb_acc
patch_user_create_sip_toggle
write_did_guard_files
write_outbound_only_context
ensure_extensions_include
protect_outbound_trunk_contexts
patch_pjsip_custom
patch_pjsip_audio
patch_rtp_conf

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
  grep -n 'extensions_outbound_only.conf' "$ASTERISK_DIR/extensions.conf" || true
  asterisk -rx "dialplan show public-did-inbound" || true
  asterisk -rx "dialplan show outbound-only" || true
  asterisk -rx "pjsip show endpoint anonymous" || true
  asterisk -rx "pjsip show registrations" || true
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
