# Apply the script on the Magnus server first

Run these commands as `root` after MagnusBilling installation is complete:

```bash
cd /root
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/setup.sh -o /root/setup.sh
chmod +x /root/setup.sh
bash /root/setup.sh
```

The script will ask for three optional things:

```text
Public IP for Asterisk NAT/audio
Local/private network CIDR
Fail2Ban ignore IPs/CIDR ranges
```

Use these simple rules when answering:

- If the script shows the correct detected public IP, press `Enter`.
- If the server has no private/local network, type `skip` for local network.
- If you want to stop fail2ban from banning your admin/team IPs, enter them separated by spaces or commas.
- If you do not want to add fail2ban ignore IPs now, press `Enter`.

Fail2Ban example:

```text
1.2.3.4 5.6.7.0/24
```

If you want to pass everything in one command instead of answering prompts:

```bash
bash /root/setup.sh --public-ip YOUR_PUBLIC_MAGNUS_IP --local-net YOUR_PRIVATE_NETWORK_CIDR --fail2ban-ignore "YOUR_OFFICE_IP YOUR_VPN_CIDR"
```

To preview without changing files:

```bash
bash /root/setup.sh --dry-run
```

# Magnus Production Setup Guide

This guide explains how to make MagnusBilling work as a provider for external PBXs like 3CX, Aheeva, Icon, and FreePBX.

The most important model is:

```text
Customer PBXs = SIP Users in context billing
Provider carriers = Trunks
DID catch-all = public-did-inbound
```

In simple terms:

- External PBXs connect to Magnus using SIP username/password.
- Magnus bills the correct SIP user/account.
- Provider trunks like Voxbeam or MyVoIP stay separate from customer SIP users.
- Inbound DIDs use the catch-all DID context, not one trunk per DID.

## Quick Search Index

Use `Ctrl+F` on Windows/Linux or `Cmd+F` on Mac and search one of these codes.

Most common tasks:

```text
MENU_MAP              Find where each Magnus menu is located
TERMS                 Understand basic Magnus words
CREATE_CUSTOMER       Create a customer/user account
AUTO_SIP_TOGGLE       Choose whether customer creation also creates a SIP user
ADD_CREDIT            Add balance to a customer
CREATE_SIP_USER       Create SIP login for FreePBX, 3CX, Aheeva, Icon
CREATE_PROVIDER       Create carrier/provider record
CREATE_TRUNK          Create provider trunk
CREATE_TRUNK_GROUP    Create trunk group
CREATE_PLAN           Create customer rate plan
CREATE_TARIFF         Create rates and routes
ROUTE_BY_COUNTRY      Route US and Nigeria through different providers
ADD_DID               Add inbound DID
SUCCESSFUL_CALLS      Check completed calls
FAILED_CALLS          Check failed calls
MAIL_SETUP            Configure SMTP and admin email notifications
DAILY_TASKS           Change password, caller ID, disable user, check calls
```

Technical setup:

```text
PRODUCTION_CODE_CHANGES Exact files/code that must be added on production
BACKUP_FIRST          Backup production before changes
MB_ACC                Check MB_ACC generation
AUTO_SIP_TOGGLE       Optional SIP auto-create checkbox
CUSTOMER_PBX_MODEL    Keep PBXs as SIP users, not trunks
PROVIDER_TRUNKS       Keep provider trunks separate
DID_CATCH_ALL         DID catch-all context
PJSIP_CUSTOM          PJSIP custom config
AUDIO_RTP             NAT, audio, RTP ports
GENERATED_SIP_USERS   Check generated SIP users
RELOAD_ASTERISK       Reload after changes
TEST_OUTBOUND         Test customer PBX outbound
PROVIDER_ERRORS       Provider error codes
TEST_DID_INBOUND      Test DID inbound
FINAL_MODEL           Final architecture model
```

Troubleshooting search terms:

```text
SIP not registered
No audio
403 Forbidden CLI
428 Use Identity Header
480 Temporarily not available
486 Busy here
Wrong trunk prefix
Provider rejected caller ID
Insufficient credit
User inactive
No route
```

## [PRODUCTION_CODE_CHANGES] Exact Production Code Changes

Use this section to understand what the script applies on production.

```text
Recommended method: run setup.sh instead of manually copying every code block.
```

The script also adds the `SIP user: Create automatically` checkbox to `Clients -> Users -> Add`.

### Change 1: Add MB_ACC to generated SIP users

File:

```text
/var/www/html/mbilling/protected/components/AsteriskAccess.php
```

Search:

```bash
grep -n 'set_var=MB_ACC' /var/www/html/mbilling/protected/components/AsteriskAccess.php
```

Expected code:

```php
$line .= "set_var=MB_ACC=" . $sip->idUser->username . "\n";
```

If missing, add it inside the SIP user endpoint generator, near the other generated endpoint lines. On the test server it is placed with the generated PJSIP endpoint options so every SIP user gets:

```ini
set_var=MB_ACC=<magnus_username>
context=billing
```

Why this is needed:

```text
Magnus billing uses MB_ACC to identify which customer account should be billed.
Without MB_ACC, external PBX calls may reach the billing context but not bill the correct user.
```

After saving, regenerate/reload Asterisk configuration from Magnus if required, then verify:

```bash
grep -n 'set_var=MB_ACC\|context=billing' /etc/asterisk/pjsip_magnus_user.conf
```

Expected example:

```ini
[freepbx]
type=endpoint
set_var=MB_ACC=freepbx
context=billing
auth=freepbx_auth
aors=freepbx
```

### Change 1B: Add Optional SIP Auto-Create Checkbox

Files:

```text
/var/www/html/mbilling/protected/controllers/UserController.php
/var/www/html/mbilling/*/app.js
```

Purpose:

```text
Clients -> Users -> Add should allow the operator to choose whether Magnus creates the SIP user automatically.
```

Expected behavior after the change:

- The `SIP user: Create automatically` checkbox appears after the password field when adding a customer/user.
- Unchecked is the default.
- If checked, Magnus keeps the normal behavior and creates the SIP user.
- If unchecked, Magnus creates only the customer/user record.
- Existing SIP users are not deleted when editing a user.

Recommended method:

```bash
bash /root/setup.sh
```

Verify:

```bash
grep -n 'create_sip_user\|shouldCreateSipUser' /var/www/html/mbilling/protected/controllers/UserController.php
grep -R 'name:"create_sip_user"' /var/www/html/mbilling/*/app.js | wc -l
```

### Change 2: Keep customer SIP users in billing context

Generated customer SIP users must have:

```ini
context=billing
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
```

Check:

```bash
asterisk -rx "pjsip show endpoint freepbx"
```

Expected:

```text
context = billing
direct_media = false
rtp_symmetric = true
force_rport = true
rewrite_contact = true
```

Do not put customer PBXs in provider trunk context.

### Change 3: Add DID catch-all endpoint

File:

```text
/etc/asterisk/pjsip_custom.conf
```

Add or confirm:

```ini
[global]
type=global
endpoint_identifier_order=ip,auth_username,username,anonymous

[anonymous]
type=endpoint
context=public-did-inbound
disallow=all
allow=ulaw,alaw,g729,gsm
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
allow_subscribe=no
```

Why this is needed:

```text
Some one-way DID providers send inbound calls to the Magnus IP without SIP registration.
The anonymous endpoint receives those calls, but sends them only to public-did-inbound first.
It must not send anonymous provider calls directly to billing.
```

### Change 4: Add DID guard dialplan include

File:

```text
/etc/asterisk/extensions.conf
```

Add this include if it is missing:

```ini
#include extensions_public_did.conf
```

Then create:

```text
/etc/asterisk/extensions_public_did.conf
```

Content:

```ini
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
```

Why this is needed:

```text
This creates a safe catch-all for inbound DIDs.
Only numbers that exist as active DIDs are allowed into billing.
Unknown numbers are rejected.
```

### Change 5: Add DID guard AGI script

File:

```text
/var/www/html/mbilling/resources/asterisk/public_did_guard.php
```

Content:

```php
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
```

Make executable:

```bash
chmod 755 /var/www/html/mbilling/resources/asterisk/public_did_guard.php
chown asterisk:asterisk /var/www/html/mbilling/resources/asterisk/public_did_guard.php
```

If production uses a different web/server user, use the same owner as other AGI scripts in:

```bash
ls -l /var/www/html/mbilling/resources/asterisk/
```

### Change 6: Set Magnus audio/NAT settings

File:

```text
/etc/asterisk/pjsip.conf
```

In the active UDP transport, use:

```ini
[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060
allow_reload = yes
external_signaling_address = YOUR_PUBLIC_MAGNUS_IP
external_media_address = YOUR_PUBLIC_MAGNUS_IP
local_net = YOUR_PRIVATE_NETWORK_CIDR
```

Example:

```ini
external_signaling_address = YOUR_PUBLIC_MAGNUS_IP
external_media_address = YOUR_PUBLIC_MAGNUS_IP
local_net = YOUR_PRIVATE_NETWORK_CIDR
```

File:

```text
/etc/asterisk/rtp.conf
```

Use:

```ini
rtpstart=10000
rtpend=20000
```

Firewall must allow:

```text
UDP 5060
UDP 10000-20000
```

Provider trunks and customer SIP users should have:

```ini
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
```

### Change 7: Provider trunk model

Provider trunks can be IP-based or registration-based.

Keep provider trunks in:

```text
Routes -> Trunks
```

Do not create one customer trunk per external PBX. External PBXs should use:

```text
Clients -> SIP Users
```

### Change 8: Reload after changes

Run:

```bash
asterisk -rx "dialplan reload"
asterisk -rx "pjsip reload"
```

Then verify:

```bash
asterisk -rx "pjsip show endpoint anonymous"
asterisk -rx "dialplan show public-did-inbound"
asterisk -rx "pjsip show endpoint freepbx"
asterisk -rx "pjsip show registrations"
```

### Change 9: Test after production changes

Outbound PBX test:

```text
External PBX -> Magnus SIP user -> billing -> provider trunk
```

Check:

```bash
asterisk -rvvvvv
```

Expected signs:

```text
PJSIP/<sip_username>
AUTHENTICATION BY ACCOUNTCODE:<username>
USERNAME=<username>
DIAL pjsip/<number>@<provider_trunk>
```

Inbound DID test:

```text
Provider DID INVITE -> anonymous -> public-did-inbound -> DID guard -> billing
```

Expected signs:

```text
PJSIP/anonymous
public-did-inbound
PUBLIC_DID_OK=1
Goto billing,<DID>,1
```

## [MENU_MAP] Beginner Menu Map

Use this map when looking for screens inside MagnusBilling:

```text
Clients -> Users
Clients -> SIP Users
Clients -> Calls Online

Billing -> Refills

DIDs -> DIDs
DIDs -> DID Destination

Rates -> Plans
Rates -> Tariffs
Rates -> Prefixes

Reports -> CDR
Reports -> CDR Failed

Routes -> Providers
Routes -> Trunks
Routes -> Trunk Groups
Routes -> Provider Rates

Settings -> Configuration
Settings -> Emails Templates
Settings -> SMTP
```

In most screens:

- Click the `Add` or `+` button to create a new record.
- Click one row, then click `Edit` to change it.
- Click `Save` after entering values.
- Use `Search` or filters at the top of the grid to find a user, trunk, DID, or call.

## [TERMS] Beginner Terms

`User`

The customer billing account. The user owns the balance, rate plan, SIP accounts, DIDs, and call records.

`SIP User`

The SIP login used by a PBX, softphone, or device. For this project, external PBXs like FreePBX, 3CX, Aheeva, and Icon must connect to Magnus as SIP users.

`Provider`

The company/carrier that provides upstream call routes, for example Voxbeam or MYVOIP.

`Trunk`

The SIP connection from Magnus to a provider. A trunk is used to send calls out to the carrier.

`Trunk Group`

A group of one or more trunks. Rates point to trunk groups, not directly to individual trunks.

`Plan`

The billing plan assigned to a user. A user can only call destinations that exist in the user's plan.

`Tariff`

The selling rate/routing rule inside a plan. It decides the destination prefix, customer price, and trunk group.

`Prefix`

The start of the dialed number. Example: `1` for US, `234` for Nigeria. Prefixes help Magnus choose the correct route.

`DID`

An inbound phone number. The provider sends the call to Magnus, then Magnus sends it to the configured destination.

`CDR`

Call Detail Record. This is where completed calls are shown.

`CDR Failed`

Failed call records. Use this screen to see provider errors like `403`, `428`, `480`, or `486`.

## [CREATE_CUSTOMER] Basic Operation: Create a Customer

Use this when adding a new company/customer that will make calls through Magnus.

Click:

```text
Clients -> Users -> Add
```

Fill the important fields:

```text
Username: customer login name, for example customer_freepbx
Password: strong portal password
Email: customer email address
Plan: select the rate plan this customer should use
Group: usually Client/Customer group
Default group: Client is selected automatically for new users
SIP user / Create automatically: default is unchecked; check it only if this customer should immediately get a SIP login
Active: Yes
Credit: starting balance, if the field is available
```

Save the user.

After saving:

- Go to `Clients -> Users`.
- Search for the username.
- Confirm `Active` is enabled.
- Confirm the correct `Plan` is selected.

Common mistakes:

- User is inactive.
- No plan is selected.
- User has no credit.
- User is assigned to the wrong group.

## [AUTO_SIP_TOGGLE] Choose Whether User Creation Also Creates a SIP User

Use this when creating a customer from:

```text
Clients -> Users -> Add
```

Field:

```text
SIP user: Create automatically
```

Leave it unchecked when you only want to create the customer billing account.

Check it when the customer needs a SIP login immediately for FreePBX, 3CX, Aheeva, Icon, or another PBX.

Uncheck it when you only want to create the customer billing account now and create SIP details later from:

```text
Clients -> SIP Users -> Add
```

Important behavior:

- Unchecked is the default, so new customers are created without a SIP user unless the operator chooses it.
- The Group field defaults to Client for new users.
- Unchecked creates only the customer/user account.
- Editing an existing user does not delete any existing SIP user.
- If you create a SIP user later, make sure it belongs to the correct customer.

## [ADD_CREDIT] Basic Operation: Add Credit to a Customer

Use this when the customer balance is low or empty.

Click:

```text
Billing -> Refills -> Add
```

Fill:

```text
Username/User: select the customer
Credit/Amount: amount to add
Description: short note, for example Manual top-up
Payment: select the payment method if required
```

Save.

After saving:

- Go to `Clients -> Users`.
- Search for the customer.
- Confirm the credit increased.

Common mistakes:

- Adding refill to the wrong user.
- User still has no plan after adding credit.

## [CREATE_SIP_USER] Basic Operation: Create a SIP User for a PBX

Use this when connecting FreePBX, 3CX, Aheeva, Icon, or another external PBX to Magnus.

Click:

```text
Clients -> SIP Users -> Add
```

Fill:

```text
User: select the customer account that owns this SIP user
Name/Username: SIP login name, for example freepbx
Secret/Password: strong SIP password
CallerID: outbound caller ID to send to provider
Host: dynamic
Context: billing
NAT: force_rport,comedia
Directmedia: no
Qualify: yes
Allow: ulaw,alaw,g729,gsm
Status: Active
```

Save.

After saving:

- Configure the external PBX using this SIP username and password.
- Server is the Magnus public IP.
- Port is `5060`.
- Transport is `UDP`.

Check registration:

```text
Clients -> SIP Users
```

Search the SIP username and check if it appears online/registered.

Server check:

```bash
asterisk -rx "pjsip show aors"
asterisk -rx "pjsip show endpoint SIP_USERNAME"
```

Common mistakes:

- SIP user is created under the wrong customer.
- Context is not `billing`.
- Caller ID is rejected by provider.
- PBX is using a different auth username than the SIP username.

## [CREATE_PROVIDER] Basic Operation: Create a Provider

Use this before creating trunks for a carrier.

Click:

```text
Routes -> Providers -> Add
```

Fill:

```text
Provider name: carrier name, for example MYVOIP or Voxbeam
Credit control: only enable if you want Magnus to stop routes based on provider credit
Status: Active
```

Save.

Common mistakes:

- Creating customer PBXs as providers. Customer PBXs should be SIP users, not providers.

## [CREATE_TRUNK] Basic Operation: Create a Provider Trunk

Use this to send outbound calls from Magnus to an upstream carrier.

Click:

```text
Routes -> Trunks -> Add
```

Fill the important fields:

```text
Provider: select the carrier/provider
Trunk name/code: clear name, for example MYVOIP
Technology: PJSIP
Host: provider SIP IP or domain
Username/User: provider SIP username, if registration is required
Secret/Password: provider SIP password, if registration is required
Register: Yes for registration trunk, No for IP-based trunk
From user: provider username if required
Trunk prefix: prefix to add before sending the call to provider
Remove prefix: prefix to remove before sending the call to provider
Allow: ulaw,alaw,g729,gsm
NAT: yes
Directmedia: no
Qualify: yes
Status: Active
```

Prefix examples:

```text
Customer dials: 13022375528
Trunk prefix: 00000
Provider receives: 0000013022375528

Customer dials: 2347062368847
Trunk prefix: 0011101
Provider receives: 00111012347062368847
```

Only use a trunk prefix when the provider requires it.

After saving:

```bash
asterisk -rx "pjsip show registrations"
asterisk -rx "pjsip show endpoint TRUNK_NAME"
asterisk -rx "pjsip show aors"
```

Common mistakes:

- Wrong provider host.
- Wrong username/password.
- Register enabled for an IP-based trunk.
- Register disabled for a registration-based trunk.
- Wrong prefix sent to provider.
- Provider rejects caller ID.

## [CREATE_TRUNK_GROUP] Basic Operation: Create a Trunk Group

Rates use trunk groups. Even if there is only one provider trunk, create a trunk group for it.

Click:

```text
Routes -> Trunk Groups -> Add
```

Fill:

```text
Name: for example MYVOIP, Voxbeam, US Routes, Nigeria Routes
Type: use order/priority unless you specifically want random load balancing
Trunks: add the provider trunk or trunks
Weight: use 1 for normal single-trunk routing
```

Save.

Recommended groups:

```text
MYVOIP group -> MYVOIP trunk
Voxbeam group -> Voxbeam trunk
US Routes group -> preferred US carrier trunk
Nigeria Routes group -> preferred Nigeria carrier trunk
```

Common mistakes:

- Creating a tariff but not assigning a trunk group.
- Adding the wrong trunk to the group.
- Mixing customer PBX SIP users into provider trunk groups.

## [CREATE_PLAN] Basic Operation: Create a Plan

Create a plan before adding tariffs.

Click:

```text
Rates -> Plans -> Add
```

Fill:

```text
Name: customer or product plan name
Status: Active
```

Save.

Then assign this plan to the customer:

```text
Clients -> Users -> select user -> Edit -> Plan
```

Common mistakes:

- Creating tariffs in a plan but not assigning that plan to the customer.

## [CREATE_TARIFF] Basic Operation: Create Tariffs / Routes

Tariffs decide both price and route.

Click:

```text
Rates -> Tariffs -> Add
```

Fill:

```text
Plan: select the customer's plan
Dial prefix: number prefix to match
Destination: readable route name
Rate initial: selling price
Init block: billing first block, usually 1 or 60
Billing block: billing increment, usually 1 or 60
Trunk group: provider trunk group to use
Status: Active
```

Examples:

```text
US route:
Dial prefix: 1
Destination: United States
Trunk group: Voxbeam or US provider group

Nigeria route:
Dial prefix: 234
Destination: Nigeria
Trunk group: MYVOIP or Nigeria provider group

Catch-all route:
Dial prefix: leave empty or use the broadest route supported by the system
Destination: Default
Trunk group: default provider group
```

Use specific routes first. Example: create `234` for Nigeria and `1` for US, instead of sending everything through one catch-all route.

Common mistakes:

- Wrong dial prefix.
- Tariff is inactive.
- Wrong trunk group selected.
- Customer is assigned to a different plan.

## [ROUTE_BY_COUNTRY] Basic Operation: Route US Calls and Nigeria Calls Differently

Use this when providers work better for different countries.

Example:

```text
US calls -> Voxbeam trunk group
Nigeria calls -> MYVOIP trunk group
```

Steps:

1. Go to `Routes -> Trunk Groups`.
2. Create or confirm `Voxbeam` trunk group.
3. Create or confirm `MYVOIP` trunk group.
4. Go to `Rates -> Tariffs`.
5. Add/edit prefix `1` and select the Voxbeam trunk group.
6. Add/edit prefix `234` and select the MYVOIP trunk group.
7. Save.
8. Test one US call and one Nigeria call.
9. Check `Reports -> CDR` and `Reports -> CDR Failed`.

## [ADD_DID] Basic Operation: Add an Inbound DID

Use this when adding a number that customers receive calls on.

Click:

```text
DIDs -> DIDs -> Add
```

Fill:

```text
DID: number exactly as provider sends it to Magnus
User: customer that owns the DID
Status: Active
Connection charge / Monthly rate: set if billing is required
CallerID: optional, usually leave blank to pass original caller ID
```

Save.

Then set where the DID should ring:

```text
DIDs -> DID Destination -> Add
```

Fill:

```text
DID: select the DID
Destination type: SIP, IVR, Queue, or number depending on need
SIP User: select the SIP user if routing to a PBX/device
Destination number: enter number if forwarding outbound
Priority: 1 for the first destination
Status: Active
```

Common mistakes:

- DID is not active.
- DID format does not match what provider sends.
- DID has no destination.
- Destination SIP user belongs to the wrong customer.

## [SUCCESSFUL_CALLS] Basic Operation: Check Successful Calls

Click:

```text
Reports -> CDR
```

Look for:

```text
Username: customer billed
Called station: number dialed
CallerID: caller ID sent
Trunk: provider trunk used
Session time: call duration
Session bill: amount charged
```

If the call is not in `CDR`, check failed calls.

## [FAILED_CALLS] Basic Operation: Check Failed Calls

Click:

```text
Reports -> CDR Failed
```

Look for:

```text
Username/Src: customer or SIP user
Called station: number dialed
CallerID: caller ID sent
Trunk: provider trunk attempted
Hangup cause: provider/Asterisk failure code
```

Common provider errors:

```text
403: provider rejected the call or caller ID
428: provider requires Identity/STIR-SHAKEN or verified caller ID
480: provider cannot route or temporarily rejects destination
486: provider returned busy
```

## [MAIL_SETUP] Basic Operation: Configure Email / SMTP

Use this so Magnus can send account, payment, low-balance, signup, and admin notification emails.

First set the SMTP server.

Click:

```text
Settings -> SMTP -> Add
```

Fill:

```text
User: admin user, usually the main admin account
Host: SMTP hostname, for example smtp.gmail.com or mail.yourdomain.com
Username: SMTP email login
Password: SMTP password or app password
Port: 587 for TLS, 465 for SSL
Encryption: tls, ssl, or null depending on the mail provider
```

Save.

Then set admin notification options.

Click:

```text
Settings -> Configuration
```

Search for these keys and edit them:

```text
admin_email
```

Set this to the admin email address that should receive notifications.

```text
admin_received_email
```

Set this to `1` or enabled if the admin should receive copies of system emails.

```text
signup_admin_email
```

Set this to `1` or enabled if the admin should receive an email when a user signs up from the form.

Then check the email templates.

Click:

```text
Settings -> Emails Templates
```

Important templates:

```text
signup
signupconfirmed
reminder
refill
did_paid
did_unpaid
did_released
did_confirmation
plan_paid
plan_unpaid
plan_released
```

For each template you use:

```text
Status: Active
From name: company/display name
From email: email address to show as sender
Subject: clear subject
Message: email body
Language: correct language
```

Common mistakes:

- SMTP password is wrong.
- Gmail/Google account needs an app password.
- Port/encryption mismatch. Use `587/tls` or `465/ssl`.
- Admin email is not set in `Settings -> Configuration`.
- Template is inactive.
- From email is not allowed by the SMTP provider.

Server check:

```bash
mysql mbilling -e "SELECT id,id_user,host,username,encryption,port FROM pkg_smtp;"
mysql mbilling -e "SELECT config_key,config_value FROM pkg_configuration WHERE config_key IN ('admin_email','admin_received_email','signup_admin_email');"
```

## [DAILY_TASKS] Basic Operation: Daily Admin Tasks

Change a customer password:

```text
Clients -> Users -> select user -> Edit -> Password -> Save
```

Change a SIP password:

```text
Clients -> SIP Users -> select SIP user -> Edit -> Secret/Password -> Save
```

Change caller ID:

```text
Clients -> SIP Users -> select SIP user -> Edit -> CallerID -> Save
```

Disable a customer:

```text
Clients -> Users -> select user -> Edit -> Active = No -> Save
```

Disable a SIP user:

```text
Clients -> SIP Users -> select SIP user -> Edit -> Status = Inactive -> Save
```

Check active calls:

```text
Clients -> Calls Online
```

Check failed calls:

```text
Reports -> CDR Failed
```

Check completed calls:

```text
Reports -> CDR
```

## [BACKUP_FIRST] 1. Backup First

Run this before changing production:

```bash
mkdir -p /root/magnus-production-backup-$(date +%Y%m%d)

cp /etc/asterisk/pjsip.conf /root/magnus-production-backup-$(date +%Y%m%d)/
cp /etc/asterisk/pjsip_custom.conf /root/magnus-production-backup-$(date +%Y%m%d)/
cp /etc/asterisk/extensions.conf /root/magnus-production-backup-$(date +%Y%m%d)/
cp /etc/asterisk/pjsip_magnus.conf /root/magnus-production-backup-$(date +%Y%m%d)/
cp /etc/asterisk/pjsip_magnus_user.conf /root/magnus-production-backup-$(date +%Y%m%d)/

mysqldump mbilling pkg_trunk pkg_sip pkg_did pkg_did_destination pkg_user > /root/magnus-production-backup-$(date +%Y%m%d)/magnus-core-tables.sql
```

If MySQL needs a password, add `-u root -p`.

## [MB_ACC] 2. Check MB_ACC Generation

Magnus must generate `MB_ACC` for every SIP user.

Check this file:

```bash
grep -n 'set_var=MB_ACC' /var/www/html/mbilling/protected/components/AsteriskAccess.php
```

Expected line:

```php
$line .= "set_var=MB_ACC=" . $sip->idUser->username . "\n";
```

If this line already exists, do not change anything.

If it does not exist, add it in the SIP-user endpoint generator after:

```php
$line .= "transport=transport-udp\n";
```

Add:

```php
$line .= "set_var=MB_ACC=" . $sip->idUser->username . "\n";
```

## [CUSTOMER_PBX_MODEL] 3. Customer PBXs Must Be SIP Users

For every external PBX, create a normal Magnus SIP user.

Examples:

- `customer_3cx`
- `customer_aheeva`
- `customer_icon`
- `customer_freepbx`

Each SIP user should have:

```text
host = dynamic
context = billing
status = active
strong SIP password
```

Do not create provider trunks for customer PBXs.

## [PROVIDER_TRUNKS] 4. Provider Trunks Stay Separate

Provider trunks are only for upstream providers.

Examples:

- Voxbeam
- MyVoIP
- other carriers

Provider trunks can be:

- IP based
- registration based

They should stay in Magnus trunk settings, not SIP user settings.

For outbound carrier trunks, use:

```text
context = billing
```

Do not set outbound carrier trunks to `public-did-inbound`. The DID catch-all context is only for the anonymous DID entry point.

## [DID_CATCH_ALL] 5. DID Catch-All Stays Separate

Inbound DID catch-all should not go directly to `billing`.

It should use:

```text
public-did-inbound
```

This context checks if the called DID exists and is active before sending the call to `billing`.

Customer SIP users should stay on:

```text
billing
```

## [PJSIP_CUSTOM] 6. Check PJSIP Custom Config

Open:

```bash
nano /etc/asterisk/pjsip_custom.conf
```

Make sure global endpoint order exists:

```ini
[global]
type=global
endpoint_identifier_order=ip,auth_username,username,anonymous
```

Make sure anonymous DID catch-all exists:

```ini
[anonymous]
type=endpoint
context=public-did-inbound
disallow=all
allow=ulaw,alaw,g729,gsm
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
allow_subscribe=no
```

## [AUDIO_RTP] 7. Check Audio / RTP Settings

These are the audio/NAT settings used on the test server.

Open:

```bash
nano /etc/asterisk/pjsip.conf
```

The active UDP transport should use port `5060` only:

```ini
[transport-udp]
type = transport
protocol = udp
bind = 0.0.0.0:5060
allow_reload = yes
external_signaling_address = YOUR_PUBLIC_MAGNUS_IP
external_media_address = YOUR_PUBLIC_MAGNUS_IP
local_net = YOUR_PRIVATE_NETWORK_CIDR
```

Example from the test server:

```ini
external_signaling_address = YOUR_PUBLIC_MAGNUS_IP
external_media_address = YOUR_PUBLIC_MAGNUS_IP
local_net = YOUR_PRIVATE_NETWORK_CIDR
```

Open:

```bash
nano /etc/asterisk/rtp.conf
```

RTP ports should be:

```ini
rtpstart=10000
rtpend=20000
```

Make sure firewall/security groups allow UDP `10000-20000`.

Generated SIP users and trunks should include:

```ini
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
```

These settings help audio pass correctly through NAT.

## [GENERATED_SIP_USERS] 8. Check Generated SIP Users

After creating SIP users in Magnus, check:

```bash
grep -n 'set_var=MB_ACC\|context=billing\|auth=.*_auth\|aors=' /etc/asterisk/pjsip_magnus_user.conf
```

Each customer SIP user should look like this:

```ini
[customer_3cx]
type=endpoint
set_var=MB_ACC=customer_3cx
context=billing
auth=customer_3cx_auth
aors=customer_3cx
```

The value after `MB_ACC=` must be the Magnus username/account that should be billed.

## [RELOAD_ASTERISK] 9. Reload Asterisk

After changes:

```bash
asterisk -rx "dialplan reload"
asterisk -rx "pjsip reload"
```

## [TEST_OUTBOUND] 10. Test Customer PBX Outbound

On 3CX, FreePBX, Aheeva, or other PBX, add a SIP trunk/account using the Magnus SIP user details:

```text
Server: production Magnus IP
Port: 5060
Transport: UDP
Username: SIP username created in Magnus
Auth username: same SIP username
Password: SIP password from Magnus
```

Make a test outbound call.

Then check Magnus CDR:

- The call should appear under the correct user.
- The route should use the provider trunk.
- The customer PBX should not be configured as a provider trunk.

## [PROVIDER_ERRORS] 11. Provider Error Checks

If the call reaches Magnus and Magnus sends it to the provider trunk, check the provider response before changing FreePBX or the SIP user.

Useful commands:

```bash
asterisk -rx "core show channels concise"
asterisk -rx "pjsip show registrations"
asterisk -rx "pjsip show aors"
strings /var/log/asterisk/magnus | egrep -i "MYVOIP|Voxbeam|sip:|480|486|403|428"
```

Test server examples:

```text
Voxbeam: 428 Use Identity Header
Voxbeam: 403 Forbidden CLI
MYVOIP: 480 Temporarily not available
MYVOIP: 486 Busy here
```

Meaning:

- `428 Use Identity Header`: provider requires SIP Identity/STIR-SHAKEN or a verified caller ID route.
- `403 Forbidden CLI`: provider rejected the caller ID.
- `480 Temporarily not available`: provider cannot route or does not allow that destination/format.
- `486 Busy here`: provider accepted the route but returned busy from its side.

These errors mean FreePBX reached Magnus and Magnus reached the provider. Fix provider route settings, dial prefix, destination permission, or caller ID policy.

Check failed CDRs:

```bash
mysql mbilling -e "SELECT id,starttime,calledstation,src,callerid,id_trunk,terminatecauseid,hangupcause FROM pkg_cdr_failed ORDER BY id DESC LIMIT 20;"
```

Check the provider trunk prefixes:

```bash
mysql mbilling -e "SELECT id,trunkcode,host,trunkprefix,removeprefix,fromuser,user,register,status FROM pkg_trunk;"
```

Keep prefixes only when the upstream provider requires them. Different providers may need different formats.

## [TEST_DID_INBOUND] 12. Test DID Inbound

Call an active DID.

Expected flow:

```text
Provider trunk or anonymous provider INVITE
-> public-did-inbound
-> DID check
-> billing
-> assigned destination
```

If the DID does not exist or is inactive, the call should be rejected.

## [FINAL_MODEL] Final Model

Customer PBX outbound:

```text
3CX / Aheeva / FreePBX
-> Magnus SIP user
-> billing
-> provider trunk
```

DID inbound:

```text
Provider
-> public-did-inbound
-> active DID check
-> billing
```

Provider outbound:

```text
Magnus
-> Voxbeam / MyVoIP / other carrier trunk
```
