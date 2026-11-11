# Oracle OPS Installer

An interactive installer for **Oracle OPS**. You clone this repository on the application server, run one script as root,
and answer its questions. The installer downloads Oracle OPS, prepares the database objects, creates the REST API keys,
installs and starts the service, and checks the result.

Oracle APEX is not installed or configured by this installer. At the end it shows the values you enter in the APEX Web
Credentials.

## Requirements

**Application server** (where Oracle OPS runs)

- Oracle Linux 7, x86_64, with systemd
- root access (`sudo`)
- an existing operating-system user and group for the Oracle OPS service (never `root`; the installer does not create
  them)
- HTTPS access to `github.com` and to `download.oracle.com` (for the Java runtime; see "Servers without access to
  download.oracle.com" for the alternative)
- a network route to the database listener
- about 1 GB of free disk space for the installation directory

**Database server**

- Oracle Database 19c: a pluggable database (PDB) or a non-CDB database for the Oracle OPS repository
- a DBA who runs one SQL script that the installer provides

**From your Oracle OPS contact**

- the **secret key** for downloading Oracle OPS (the installer asks for it as the *access token*)

## Information to have ready

| Question | Example |
|---|---|
| Installation directory | `/u01/oracle_ops_runtime` (default) |
| Service user and group | `applmgr` / `oinstall` |
| Database host, listener port, service name | `dbhost`, `1521`, `OPSPDB` |
| REST API bind address | `127.0.0.1` if APEX/ORDS runs on this server; otherwise this server's IP address |
| IP address of the APEX/ORDS server | only when the bind address is not `127.0.0.1` |
| REST API port | `8888` (any free port from 1024 to 65535) |
| Secret key | from your Oracle OPS contact |
| `OPS_OWNER` password | chosen by the DBA when running the SQL script |
| `OPS_RUNTIME` password | chosen by the DBA when running the SQL script |
| EBS environment file (optional) | `/u01/app/UAT/EBSapps.env`, edition `run` |

## Download and run

```bash
git clone <this repository URL> oracle-ops-installer
cd oracle-ops-installer
sudo bash ./oracle-ops-installer.sh
```

If the directory you cloned into is not owned by root, the installer explains this and asks you to type `yes`. It then
copies itself into a root-only directory, runs from there and removes the copy at the end.

Choose **1) Fresh Installation** from the menu.

## Installation steps

The installer shows each step as `[n/9]`. Nothing on the server is changed before you confirm the review screen.

1. **System check** – operating system, memory, disk, required tools, existing installation. If tools are missing, the
   installer offers to install them with `yum`.
2. **Settings** – installation directory, service user and group, database host/port/service (the installer checks that
   the listener answers), REST API bind address, APEX/ORDS address (if needed) and port.
3. **Review** – all settings and the planned changes. Type `yes` to continue.
4. **Database preparation (DBA)** – choose **1** if the DBA has not prepared the database yet. The installer saves a SQL
   script (default `/root/oracle-ops-schema-<version>.sql`) and shows it on screen. Give it to the DBA, who runs it
   **in the PDB** (not in `CDB$ROOT`), for example:

   ```bash
   sqlplus system@//<db-host>:<port>/<service> @oracle-ops-schema-<version>.sql
   ```

   The script creates the tablespace `OPS_DATA`, the users `OPS_OWNER` and `OPS_RUNTIME` and their privileges. It asks
   the DBA for both passwords; they are not stored in the file. When the DBA is done, type `yes`. (If the DBA has already
   run it, choose **2**.)
5. **Download** – enter the secret key when asked for the *Access token*. It is not shown, stored or logged.
6. **Database objects** – the installer installs the Oracle OPS Java runtime, asks for the `OPS_OWNER` password, checks
   the database and, after you type `yes`, creates the Oracle OPS tables and packages. The password is not stored.
7. **REST API keys** – two keys are created in `/etc/oracle-ops`: a read key (GET APIs) and a control key (POST APIs).
8. **Oracle OPS setup** – asks for the `OPS_RUNTIME` password (it tests the login before storing it), an optional node
   name and the optional EBS settings, shows a summary, and installs and starts the `oracle-ops` service after you type
   `yes`. If you chose a network bind address, the REST API is then moved to it.
9. **Final check** – every check is listed as `[PASS]` or `[FAIL]`. When all pass, both API keys are shown.

## APEX Web Credentials

At the end of the installation (and any time later in menu **7) View API Keys**) the installer shows, for each key:

| Setting | Read key (GET APIs) | Control key (POST APIs) |
|---|---|---|
| Static ID | `OPS_API_TOKEN` | `oracle-ops-api-token-action` |
| Authentication type | HTTP Header | HTTP Header |
| Credential name | `Authorization` | `Authorization` |
| Credential secret | `Bearer <read key>` | `Bearer <control key>` |
| Valid for URLs | `http://<bind address>:<port>/` | `http://<bind address>:<port>/` |

Enter them in APEX (Workspace Utilities > Web Credentials), then press Enter: the installer clears the screen. Keep the
keys private and do not copy the screen into e-mails, chats or tickets.

When APEX/ORDS runs on another server, the API uses plain HTTP between the two servers. Allow the port only from the
APEX/ORDS server in your firewall. That server can call every API, including start/stop once `ebs.control.enabled` is `true`.
When HTTPS is added later, regenerate both API keys.

## After the installation

| Task | How |
|---|---|
| Service status | `systemctl status oracle-ops` |
| Installation status | menu **5) View Installation Status** |
| List of APIs | menu **6) View APIs** |
| Show the API keys again | menu **7) View API Keys** (type `SHOW` to display them) |
| New API keys | menu **3) Reconfigure Installation** > **3) Regenerate the REST API keys** (then update APEX) |
| Configuration | menu **8) View Configuration** |
| Upgrade | menu **2) Upgrade Existing Installation** |
| Remove | menu **9) Uninstall Oracle OPS** (stops the service and renames the installation directory; nothing is deleted, the database is not changed) |

Logs:

- installer: `/var/log/oracle-ops-installer/` (root only; secrets are never written)
- Oracle OPS service: `<installation directory>/logs/oracle-ops.log`

## Servers without access to download.oracle.com

Download the Oracle JDK archive that this Oracle OPS release uses, `jdk-21.0.12.1_linux-x64_bin.tar.gz`, from
`https://download.oracle.com/java/21/archive/` on another machine. Copy it to the server, then start the installer with
it:

```bash
sudo bash ./oracle-ops-installer.sh --java-archive /path/to/jdk-21.0.12.1_linux-x64_bin.tar.gz
```

The archive is checked against its expected SHA-256 checksum before it is used. Oracle JDK is subject to Oracle's
licence terms; check that they cover your use.

## If the installation stops

The installer prints the reason and the path of its log. Fix the cause and run the installer again: the database
objects, API keys and the Java runtime that were already created are reused, and an incomplete installation directory
is completed.
