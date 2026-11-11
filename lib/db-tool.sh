#!/bin/bash
# Oracle OPS Installer library: the database tool (0.3.0) - checks the DBA-prepared schema and creates the Oracle OPS tables
# and packages in an OPS_OWNER session, by running the pinned release's own SQL scripts unchanged.
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time.
#
# The Java source below is written into the run's root-only directory and started with the release's pinned private JDK
# (single-file source launch) and the release's own JDBC Thin driver (SHA-256 checked against service/build.sh). No Oracle
# client (SQL*Plus) is needed on the host. It is part of this verified library, so the loader's digest covers it.
#
#   OpsSchemaDeploy split <file>...                      no database: how the scripts are split (tests)
#   OpsSchemaDeploy check  <url> <views>                 OPS_OWNER password on stdin; prerequisite checks + object state
#   OpsSchemaDeploy deploy <url> <views> <file>...       check, refuse unless EMPTY, run the files in order, check again
# Output: "RESULT <id> PASS|FAIL <text>", "STATE EMPTY|COMPLETE|PARTIAL <detail>", "RUN <file>", "EXEC <n> <kind> <text>",
# "OUT <text>" (DBMS_OUTPUT and PROMPT), "ERROR <text>". Exit: 0 ok | 1 a check or a script failed | 2 usage | 3 wrong user
# name or password (ORA-01017) | 4 account locked or password expired (ORA-28000/28001) | 5 the database could not be reached.

db_tool_source() {
  cat <<'JAVA'
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.sql.CallableStatement;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.sql.Types;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Properties;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Oracle OPS Installer database tool. Never prints the password; every statement it runs comes from a verified file. */
public class OpsSchemaDeploy {

    static final String OWNER = "OPS_OWNER";
    static final String RUNTIME = "OPS_RUNTIME";
    static final String TABLESPACE = "OPS_DATA";
    static final String[] OWNER_PRIVS = {"CREATE SESSION", "CREATE TABLE", "CREATE SEQUENCE", "CREATE PROCEDURE"};
    static final String[][] OBJECTS = {
        {"OPS_RUN", "TABLE"}, {"OPS_RUN_API", "PACKAGE"}, {"OPS_RUN_API", "PACKAGE BODY"},
        {"OPS_WLS_ACTION", "TABLE"}, {"OPS_WLS_ACTION_API", "PACKAGE"}, {"OPS_WLS_ACTION_API", "PACKAGE BODY"}};
    static final String[] GRANTED_PACKAGES = {"OPS_RUN_API", "OPS_WLS_ACTION_API"};
    static final Pattern VIEW = Pattern.compile("DBA_[A-Z_]{1,60}");
    static final Pattern URL = Pattern.compile("jdbc:oracle:thin:@//[A-Za-z0-9.-]{1,253}:[0-9]{1,5}/[A-Za-z0-9_.-]{1,64}");
    static final Pattern INCLUDE = Pattern.compile("@@?\\s*([A-Za-z0-9_.-]{1,200}\\.sql)\\s*;?");
    static final Pattern PLSQL_START = Pattern.compile(
        "(?is)^(declare|begin)\\b.*|^create\\s+(or\\s+replace\\s+)?((editionable|noneditionable)\\s+)?"
        + "(package|procedure|function|trigger|type|library)\\b.*");
    static final Pattern UNIT = Pattern.compile(
        "(?is)^create\\s+(?:or\\s+replace\\s+)?(?:(?:editionable|noneditionable)\\s+)?"
        + "(package\\s+body|package|procedure|function|trigger|type\\s+body|type)\\s+(?:\"?(\\w+)\"?\\.)?\"?(\\w+)\"?.*");

    /** One unit of work found in a script. kind: SQL, PLSQL, PROMPT, SHOW_ERRORS, INCLUDE. */
    static final class Item {
        final String kind;
        final String text;
        final String source;
        Item(String kind, String text, String source) { this.kind = kind; this.text = text; this.source = source; }
    }

    static int failures = 0;

    public static void main(String[] args) {
        int rc;
        try {
            rc = run(args);
        } catch (Usage u) {
            System.out.println("ERROR usage: " + u.getMessage());
            rc = 2;
        } catch (RuntimeException e) {
            System.out.println("ERROR " + e.getClass().getSimpleName() + ": " + e.getMessage());
            rc = 1;
        }
        System.out.flush();
        System.exit(rc);
    }

    static final class Usage extends RuntimeException {
        Usage(String m) { super(m); }
    }

    static int run(String[] args) {
        if (args.length < 1) throw new Usage("split|check|deploy");
        String mode = args[0];
        if (mode.equals("split")) {
            if (args.length < 2) throw new Usage("split <file>...");
            for (int i = 1; i < args.length; i++) {
                List<Item> items = parse(Paths.get(args[i]), 0);
                int n = 0;
                for (Item it : items) {
                    n++;
                    System.out.println("EXEC " + n + " " + it.kind + " " + firstLine(it.text));
                }
                System.out.println("FILE " + args[i] + " " + items.size());
            }
            return 0;
        }
        if (!mode.equals("check") && !mode.equals("deploy")) throw new Usage("unknown mode " + mode);
        if (args.length < 3) throw new Usage(mode + " <url> <views>" + (mode.equals("deploy") ? " <file>..." : ""));
        String url = args[1];
        if (!URL.matcher(url).matches()) throw new Usage("the JDBC URL is not jdbc:oracle:thin:@//host:port/service");
        List<String> views = new ArrayList<>();
        for (String v : args[2].split(",")) {
            if (!VIEW.matcher(v).matches()) throw new Usage("not a DBA_ view name: " + v);
            views.add(v);
        }
        List<Path> files = new ArrayList<>();
        for (int i = 3; i < args.length; i++) files.add(Paths.get(args[i]));
        if (mode.equals("deploy") && files.isEmpty()) throw new Usage("deploy needs at least one file");
        // parse everything before logging in: a script the runner cannot split stops the run before any change
        List<List<Item>> parsed = new ArrayList<>();
        for (Path f : files) parsed.add(parse(f, 0));

        char[] password = readPassword();
        Connection c;
        try {
            Properties p = new Properties();
            p.setProperty("user", OWNER);
            p.setProperty("password", new String(password));
            p.setProperty("oracle.net.CONNECT_TIMEOUT", "15000");
            DriverManager.setLoginTimeout(15);
            c = DriverManager.getConnection(url, p);
            p.clear();
        } catch (SQLException e) {
            Arrays.fill(password, '\0');
            int code = e.getErrorCode();
            System.out.println("ERROR login as " + OWNER + " failed: " + oneLine(e.getMessage()));
            if (code == 1017) return 3;
            if (code == 28000 || code == 28001) return 4;
            return 5;
        }
        Arrays.fill(password, '\0');
        try {
            String state = check(c, views);
            if (failures > 0) return 1;
            if (mode.equals("check")) return 0;
            if (!state.equals("EMPTY")) {
                System.out.println("ERROR the schema is not empty (" + state + "): nothing was created");
                return 1;
            }
            c.setAutoCommit(false);
            enableOutput(c);
            for (int i = 0; i < files.size(); i++) {
                System.out.println("RUN " + files.get(i).getFileName());
                execute(c, parsed.get(i));
                c.commit();
            }
            failures = 0;
            state = check(c, views);
            if (failures > 0 || !state.equals("COMPLETE")) {
                System.out.println("ERROR the scripts ran, but the schema is not complete afterwards");
                return 1;
            }
            return 0;
        } catch (SQLException e) {
            System.out.println("ERROR ORA-" + String.format("%05d", e.getErrorCode()) + ": " + oneLine(e.getMessage()));
            try { c.rollback(); } catch (SQLException ignored) { }
            return 1;
        } finally {
            try { c.close(); } catch (SQLException ignored) { }
        }
    }

    // ---- password: one line from standard input, never echoed or printed ---------------------------------------------
    static char[] readPassword() {
        try {
            InputStream in = System.in;
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            int b;
            while ((b = in.read()) != -1 && b != '\n') buf.write(b);
            byte[] raw = buf.toByteArray();
            char[] pw = new String(raw, StandardCharsets.UTF_8).toCharArray();
            Arrays.fill(raw, (byte) 0);
            int len = pw.length;
            if (len > 0 && pw[len - 1] == '\r') len--;
            if (len == 0) throw new Usage("no password on standard input");
            return Arrays.copyOf(pw, len);
        } catch (IOException e) {
            throw new Usage("cannot read the password");
        }
    }

    // ---- checks (read-only; everything an OPS_OWNER session can see about itself) ----------------------------------------
    static void result(String id, boolean ok, String text) {
        System.out.println("RESULT " + id + " " + (ok ? "PASS" : "FAIL") + " " + text);
        if (!ok) failures++;
    }

    static String one(Connection c, String sql, String... binds) throws SQLException {
        try (PreparedStatement ps = c.prepareStatement(sql)) {
            for (int i = 0; i < binds.length; i++) ps.setString(i + 1, binds[i]);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() ? rs.getString(1) : null;
            }
        }
    }

    static int count(Connection c, String sql, String... binds) throws SQLException {
        String v = one(c, sql, binds);
        return v == null ? 0 : Integer.parseInt(v);
    }

    static String check(Connection c, List<String> views) throws SQLException {
        String user = one(c, "select sys_context('USERENV', 'SESSION_USER') from dual");
        result("session-user", OWNER.equals(user), "connected as " + user);
        String con = one(c, "select sys_context('USERENV', 'CON_NAME') from dual");
        result("container", !"CDB$ROOT".equals(con), "container " + con + ("CDB$ROOT".equals(con) ? " (connect to the PDB, not the root)" : ""));
        List<String> missing = new ArrayList<>();
        for (String p : OWNER_PRIVS) {
            if (count(c, "select count(*) from user_sys_privs where privilege = ?", p) == 0) missing.add(p);
        }
        result("owner-privileges", missing.isEmpty(), missing.isEmpty() ? String.join(", ", OWNER_PRIVS) + " granted directly"
            : "missing (must be granted directly, not through a role): " + String.join(", ", missing));
        String ts = one(c, "select status from user_tablespaces where tablespace_name = ?", TABLESPACE);
        result("tablespace", "ONLINE".equals(ts), TABLESPACE + " " + (ts == null ? "not visible to " + OWNER : ts));
        int quota = count(c, "select count(*) from user_ts_quotas where tablespace_name = ? and (max_bytes = -1 or max_bytes > 0)", TABLESPACE)
            + count(c, "select count(*) from user_sys_privs where privilege = 'UNLIMITED TABLESPACE'");
        result("quota", quota > 0, quota > 0 ? "quota on " + TABLESPACE : "no quota on " + TABLESPACE);
        result("runtime-user", count(c, "select count(*) from all_users where username = ?", RUNTIME) == 1,
            RUNTIME + (count(c, "select count(*) from all_users where username = ?", RUNTIME) == 1 ? " exists" : " does not exist"));
        List<String> noAccess = new ArrayList<>();
        for (String v : views) {
            try (Statement s = c.createStatement(); ResultSet rs = s.executeQuery("select count(*) from sys." + v + " where rownum = 1")) {
                rs.next();
            } catch (SQLException e) {
                noAccess.add(v);
            }
        }
        result("dictionary-views", noAccess.isEmpty(), noAccess.isEmpty() ? views.size() + " DBA_ views readable"
            : "not readable (the DBA SQL grants SELECT on them): " + String.join(", ", noAccess));

        int present = 0, valid = 0;
        List<String> detail = new ArrayList<>();
        for (String[] o : OBJECTS) {
            String st = one(c, "select status from user_objects where object_name = ? and object_type = ?", o[0], o[1]);
            if (st != null) {
                present++;
                if ("VALID".equals(st)) valid++;
                detail.add(o[0] + " " + o[1] + " " + st);
            }
        }
        int grants = 0;
        for (String p : GRANTED_PACKAGES) {
            grants += count(c, "select count(*) from user_tab_privs_made where grantee = ? and table_name = ? and privilege = 'EXECUTE'",
                RUNTIME, p);
        }
        int others = count(c, "select count(*) from user_objects where object_name not like 'OPS\\_%' escape '\\' "
            + "and object_name not like 'ISEQ$$\\_%' escape '\\' and object_name not like 'SYS\\_%' escape '\\'");
        String state;
        if (present == 0 && grants == 0) state = "EMPTY";
        else if (present == OBJECTS.length && valid == OBJECTS.length && grants == GRANTED_PACKAGES.length) state = "COMPLETE";
        else state = "PARTIAL";
        System.out.println("STATE " + state + " objects=" + present + "/" + OBJECTS.length + " valid=" + valid + " grants="
            + grants + "/" + GRANTED_PACKAGES.length + " other-objects=" + others + (detail.isEmpty() ? "" : " (" + String.join("; ", detail) + ")"));
        return state;
    }

    // ---- the script parser: the SQL*Plus subset the Oracle OPS scripts use ---------------------------------------------------
    static List<Item> parse(Path file, int depth) {
        if (depth > 3) throw new IllegalStateException("includes nested too deeply in " + file);
        List<String> lines;
        try {
            lines = Files.readAllLines(file, StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("cannot read " + file.getFileName());
        }
        String src = file.getFileName().toString();
        List<Item> out = new ArrayList<>();
        StringBuilder buf = new StringBuilder();
        boolean plsql = false;
        boolean inBlockComment = false;
        for (String raw : lines) {
            String line = raw.replace("\r", "");
            String t = line.trim();
            if (buf.length() == 0) {
                if (inBlockComment) { if (t.contains("*/")) inBlockComment = false; continue; }
                if (t.isEmpty() || t.startsWith("--")) continue;
                if (t.startsWith("/*")) { if (!t.contains("*/")) inBlockComment = true; continue; }
                String w = t.toLowerCase(Locale.ROOT);
                String first = w.split("\\s+")[0];
                if (first.equals("whenever") || first.equals("set") || first.equals("rem") || first.equals("remark")
                        || first.equals("spool") || (first.equals("/") )) continue;
                if (first.equals("exit") || first.equals("quit")) break;
                if (first.equals("prompt") || first.equals("pro")) { out.add(new Item("PROMPT", t.length() > first.length() ? t.substring(first.length()).trim() : "", src)); continue; }
                if (w.startsWith("show err")) { out.add(new Item("SHOW_ERRORS", t, src)); continue; }
                if (t.startsWith("@")) {
                    Matcher m = INCLUDE.matcher(t);
                    if (!m.matches()) throw new IllegalStateException(src + ": unsupported include: " + t);
                    Path inc = file.resolveSibling(m.group(1));
                    out.addAll(parse(inc, depth + 1));
                    continue;
                }
                if (first.equals("define") || first.equals("accept") || first.equals("connect") || first.equals("conn")
                        || first.equals("host") || first.equals("!") || first.equals("variable") || first.equals("var")
                        || first.equals("exec") || first.equals("execute") || first.equals("column") || first.equals("col")) {
                    throw new IllegalStateException(src + ": SQL*Plus command not supported by the installer: " + first);
                }
                plsql = PLSQL_START.matcher(t).matches();
            }
            if (plsql) {
                if (t.equals("/")) { out.add(new Item("PLSQL", rtrim(buf.toString()), src)); buf.setLength(0); continue; }
                buf.append(line).append('\n');
            } else {
                if (t.equals("/")) { out.add(new Item("SQL", stripSemicolon(rtrim(buf.toString())), src)); buf.setLength(0); continue; }
                buf.append(line).append('\n');
                if (endsWithTerminator(buf.toString())) {
                    out.add(new Item("SQL", stripSemicolon(rtrim(buf.toString())), src));
                    buf.setLength(0);
                }
            }
        }
        if (buf.toString().trim().length() > 0) throw new IllegalStateException(src + ": the last statement is not terminated");
        return out;
    }

    /** True when the text ends with ';' outside string literals and comments. */
    static boolean endsWithTerminator(String s) {
        boolean inStr = false, inBlock = false, lastSemi = false;
        for (int i = 0; i < s.length(); i++) {
            char ch = s.charAt(i);
            char nx = i + 1 < s.length() ? s.charAt(i + 1) : '\0';
            if (inBlock) { if (ch == '*' && nx == '/') { inBlock = false; i++; } continue; }
            if (inStr) { if (ch == '\'') { if (nx == '\'') i++; else inStr = false; } continue; }
            if (ch == '-' && nx == '-') { while (i < s.length() && s.charAt(i) != '\n') i++; continue; }
            if (ch == '/' && nx == '*') { inBlock = true; i++; continue; }
            if (ch == '\'') { inStr = true; lastSemi = false; continue; }
            if (Character.isWhitespace(ch)) continue;
            lastSemi = ch == ';';
        }
        return lastSemi && !inStr && !inBlock;
    }

    static String stripSemicolon(String s) {
        String r = rtrim(s);
        while (r.endsWith(";")) r = rtrim(r.substring(0, r.length() - 1));
        return r;
    }

    static String rtrim(String s) {
        int e = s.length();
        while (e > 0 && Character.isWhitespace(s.charAt(e - 1))) e--;
        return s.substring(0, e);
    }

    static String firstLine(String s) {
        String f = s.split("\n", 2)[0].trim();
        return f.length() > 100 ? f.substring(0, 100) : f;
    }

    static String oneLine(String s) {
        return s == null ? "" : s.replace('\n', ' ').replace('\r', ' ').trim();
    }

    // ---- execution -------------------------------------------------------------------------------------------------------
    static String lastUnitName = null;
    static String lastUnitType = null;

    static void enableOutput(Connection c) throws SQLException {
        try (CallableStatement cs = c.prepareCall("begin dbms_output.enable(null); end;")) { cs.execute(); }
    }

    static void drainOutput(Connection c) throws SQLException {
        try (CallableStatement cs = c.prepareCall("begin dbms_output.get_line(?, ?); end;")) {
            cs.registerOutParameter(1, Types.VARCHAR);
            cs.registerOutParameter(2, Types.INTEGER);
            for (int i = 0; i < 10000; i++) {
                cs.execute();
                if (cs.getInt(2) != 0) break;
                String l = cs.getString(1);
                System.out.println("OUT " + (l == null ? "" : l));
            }
        }
    }

    static void compileErrors(Connection c, String name, String type) throws SQLException {
        int n = count(c, "select count(*) from user_errors where name = ? and type = ? and attribute = 'ERROR'", name, type);
        if (n == 0) return;
        try (PreparedStatement ps = c.prepareStatement(
                "select line, position, text from user_errors where name = ? and type = ? and attribute = 'ERROR' order by sequence")) {
            ps.setString(1, name);
            ps.setString(2, type);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    System.out.println("ERROR " + type + " " + name + " line " + rs.getInt(1) + "/" + rs.getInt(2) + ": " + oneLine(rs.getString(3)));
                }
            }
        }
        throw new IllegalStateException(type + " " + name + " compiled with " + n + " error(s)");
    }

    static void execute(Connection c, List<Item> items) throws SQLException {
        int n = 0;
        for (Item it : items) {
            n++;
            switch (it.kind) {
                case "PROMPT":
                    System.out.println("OUT " + it.text);
                    continue;
                case "SHOW_ERRORS":
                    if (lastUnitName != null) compileErrors(c, lastUnitName, lastUnitType);
                    continue;
                default:
                    break;
            }
            System.out.println("EXEC " + n + " " + it.kind + " " + it.source + ": " + firstLine(it.text));
            try (Statement s = c.createStatement()) {
                s.setEscapeProcessing(false);
                s.execute(it.text);
            } catch (SQLException e) {
                drainOutput(c);
                throw e;
            }
            drainOutput(c);
            Matcher m = UNIT.matcher(it.text.trim());
            if (m.matches()) {
                lastUnitType = m.group(1).toUpperCase(Locale.ROOT).replaceAll("\\s+", " ");
                lastUnitName = m.group(3).toUpperCase(Locale.ROOT);
                compileErrors(c, lastUnitName, lastUnitType);
            }
        }
    }
} // OpsSchemaDeploy
JAVA
}
