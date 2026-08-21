/* BLOB columns fire-crab's own DDL creates: DESCRIBE of every column
   (sqltype / sqlsubtype / sqlscale - the CHARACTER SET of a text blob -
   / sqllen), literals stored into blob columns and read back, and the
   filter laws (isc_nofilter between sub_types, a declared filter whose
   module is not there). Prints status vectors raw where an error is the
   answer. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static ISC_STATUS st[20];
static isc_db_handle db = 0; static isc_tr_handle tr = 0;
static void vec(void) {
    const ISC_STATUS *p = st;
    if (p[0] != isc_arg_gds || p[1] == 0) { printf(" ok\n"); return; }
    while (*p != isc_arg_end) {
        switch (*p) {
        case isc_arg_gds: printf(" gds %ld", (long)p[1]); p += 2; break;
        case isc_arg_string: printf(" str '%s'", (const char *)p[1]); p += 2; break;
        case isc_arg_cstring: printf(" cstr '%.*s'", (int)p[1], (const char *)p[2]); p += 3; break;
        case isc_arg_number: printf(" num %ld", (long)p[1]); p += 2; break;
        case isc_arg_interpreted: printf(" interp '%s'", (const char *)p[1]); p += 2; break;
        case isc_arg_sql_state: printf(" sqlstate '%s'", (const char *)p[1]); p += 2; break;
        default: printf(" arg%ld", (long)*p); p += 2;
        }
    }
    printf("\n");
}
static void exec(const char *sql) { printf("%s\n  ->", sql); isc_dsql_execute_immediate(st, &db, &tr, 0, sql, 3, NULL); vec(); }
static void commit(void) { isc_commit_transaction(st, &tr); tr = 0; if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) { printf("start:"); vec(); exit(1); } }
static void describe(const char *sql) {
    isc_stmt_handle sth = 0; XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(20)); out->version = SQLDA_VERSION1; out->sqln = 20;
    printf("describe %s\n", sql);
    if (isc_dsql_allocate_statement(st, &db, &sth)) { printf("  alloc:"); vec(); return; }
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, out)) { printf("  ->"); vec(); isc_dsql_free_statement(st, &sth, DSQL_drop); free(out); return; }
    for (int i = 0; i < out->sqld; i++) { XSQLVAR *v = &out->sqlvar[i]; printf("  %.*s: type %d subtype %d scale %d len %d\n", v->sqlname_length, v->sqlname, v->sqltype, v->sqlsubtype, v->sqlscale, v->sqllen); }
    isc_dsql_free_statement(st, &sth, DSQL_drop); free(out);
}
static void readtext(const char *sql) {
    /* fetch one VARCHAR column */
    isc_stmt_handle sth = 0; XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(1)); out->version = SQLDA_VERSION1; out->sqln = 1;
    char buf[66]; short ind = 0;
    printf("%s\n  ->", sql);
    if (isc_dsql_allocate_statement(st, &db, &sth)) { vec(); return; }
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, out)) { vec(); goto done; }
    out->sqlvar[0].sqltype = SQL_VARYING + 1; out->sqlvar[0].sqldata = buf; out->sqlvar[0].sqllen = 64; out->sqlvar[0].sqlind = &ind;
    if (isc_dsql_execute(st, &tr, &sth, 1, NULL)) { vec(); goto done; }
    { ISC_STATUS rc = isc_dsql_fetch(st, &sth, 1, out);
      if (rc == 100) printf(" no rows\n"); else if (rc) vec(); else { unsigned short n; memcpy(&n, buf, 2); printf(" '%.*s'\n", n, buf + 2); } }
done:
    isc_dsql_free_statement(st, &sth, DSQL_drop); free(out);
}
/* fetch the blob id of a one-column SELECT and read the blob's bytes
   through the blob API - with an optional bpb naming a source/target
   sub_type, which is where a filter would be asked for */
static void readblob(const char *sql, int with_bpb, int from, int to) {
    isc_stmt_handle sth = 0; XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(1)); out->version = SQLDA_VERSION1; out->sqln = 1;
    ISC_QUAD id; short ind = 0;
    if (with_bpb) printf("%s [bpb source %d target %d]\n  ->", sql, from, to); else printf("%s [blob api]\n  ->", sql);
    if (isc_dsql_allocate_statement(st, &db, &sth)) { vec(); return; }
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, out)) { vec(); goto done; }
    out->sqlvar[0].sqltype = SQL_BLOB + 1; out->sqlvar[0].sqldata = (char *)&id; out->sqlvar[0].sqllen = 8; out->sqlvar[0].sqlind = &ind;
    if (isc_dsql_execute(st, &tr, &sth, 1, NULL)) { vec(); goto done; }
    { ISC_STATUS rc = isc_dsql_fetch(st, &sth, 1, out);
      if (rc == 100) { printf(" no rows\n"); goto done; } if (rc) { vec(); goto done; }
      if (ind < 0) { printf(" null\n"); goto done; } }
    { isc_blob_handle bh = 0; char bpb[8]; int n = 0;
      bpb[n++] = isc_bpb_version1; bpb[n++] = isc_bpb_source_type; bpb[n++] = 1; bpb[n++] = (char)from; bpb[n++] = isc_bpb_target_type; bpb[n++] = 1; bpb[n++] = (char)to;
      if (isc_open_blob2(st, &db, &tr, &bh, &id, with_bpb ? n : 0, with_bpb ? bpb : NULL)) { vec(); goto done; }
      char seg[256]; unsigned short got = 0; char all[1024]; int tot = 0; ISC_STATUS rc;
      while ((rc = isc_get_segment(st, &bh, &got, sizeof seg, seg)) == 0 || rc == isc_segment) { if (tot + got < (int)sizeof all) { memcpy(all + tot, seg, got); tot += got; } }
      if (rc != isc_segstr_eof) { vec(); isc_close_blob(st, &bh); goto done; }
      isc_close_blob(st, &bh);
      printf(" '%.*s'\n", tot, all); }
done:
    isc_dsql_free_statement(st, &sth, DSQL_drop); free(out);
}
int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: blobcol <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    char dpb[64]; int n = 0; dpb[n++] = isc_dpb_version1;
    dpb[n++] = isc_dpb_user_name; dpb[n++] = 6; memcpy(dpb + n, "SYSDBA", 6); n += 6;
    dpb[n++] = isc_dpb_password; dpb[n++] = 9; memcpy(dpb + n, "masterkey", 9); n += 9;
    if (isc_attach_database(st, 0, argv[1], &db, n, dpb)) { printf("attach:"); vec(); return 1; }
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) { printf("start:"); vec(); return 1; }
    exec("CREATE TABLE BC (ID INT NOT NULL PRIMARY KEY, B BLOB, T BLOB SUB_TYPE TEXT, N BLOB SUB_TYPE -5, S BLOB SEGMENT SIZE 100, TC BLOB SUB_TYPE TEXT CHARACTER SET UTF8, BIN BLOB SUB_TYPE BINARY, Z BLOB SUB_TYPE 0, U BLOB SUB_TYPE 1)");
    exec("CREATE TABLE BAD (ID INT, X BLOB SUB_TYPE 2)");
    exec("CREATE TABLE BAD2 (ID INT, X BLOB SUB_TYPE 99)");
    commit();
    describe("SELECT * FROM BC");
    exec("INSERT INTO BC (ID, Z) VALUES (1, 'abc')");
    exec("INSERT INTO BC (ID, T) VALUES (2, 'text two')");
    exec("INSERT INTO BC (ID, B) VALUES (3, 'abc')");
    exec("INSERT INTO BC (ID, N) VALUES (4, 'abc')");
    exec("INSERT INTO BC (ID, N) VALUES (5, _octets 'abc')");
    exec("INSERT INTO BC (ID, TC) VALUES (6, 'utf8 text')");
    exec("INSERT INTO BC (ID, S, U) VALUES (7, 'seg', 'u one')");
    exec("UPDATE BC SET N = 'zzz' WHERE ID = 5");
    exec("UPDATE BC SET N = _octets 'zzz' WHERE ID = 5");
    exec("UPDATE BC SET T = 'text two again' WHERE ID = 2");
    exec("UPDATE BC SET N = 'nothing' WHERE ID = 99");
    commit();
    readblob("SELECT Z FROM BC WHERE ID = 1", 0, 0, 0);
    readblob("SELECT T FROM BC WHERE ID = 2", 0, 0, 0);
    readblob("SELECT B FROM BC WHERE ID = 3", 0, 0, 0);
    readblob("SELECT N FROM BC WHERE ID = 5", 0, 0, 0);
    readblob("SELECT TC FROM BC WHERE ID = 6", 0, 0, 0);
    readblob("SELECT S FROM BC WHERE ID = 7", 0, 0, 0);
    readblob("SELECT U FROM BC WHERE ID = 7", 0, 0, 0);
    /* a bpb asking for a conversion: a filter is looked up only between
       two different non-zero sub_types */
    readblob("SELECT N FROM BC WHERE ID = 5", 1, -5, 1);
    readblob("SELECT N FROM BC WHERE ID = 5", 1, -5, -5);
    readblob("SELECT N FROM BC WHERE ID = 5", 1, -5, 0);
    readblob("SELECT N FROM BC WHERE ID = 5", 1, 0, -5);
    readblob("SELECT T FROM BC WHERE ID = 2", 1, 1, -7);
    readblob("SELECT T FROM BC WHERE ID = 2", 1, 1, 0);
    readblob("SELECT T FROM BC WHERE ID = 2", 1, 0, 1);
    readtext("SELECT CAST(COUNT(*) AS VARCHAR(5)) FROM BC WHERE N IS NULL");
    /* the filter catalog */
    exec("DECLARE FILTER F1 INPUT_TYPE 1 OUTPUT_TYPE -5 ENTRY_POINT 'ep' MODULE_NAME 'nomod'");
    exec("DECLARE FILTER F2 INPUT_TYPE 0 OUTPUT_TYPE -7 ENTRY_POINT 'ep2' MODULE_NAME 'nomod'");
    commit();
    readtext("SELECT CAST(TRIM(RDB$FUNCTION_NAME) || '|' || TRIM(RDB$MODULE_NAME) || '|' || TRIM(RDB$ENTRYPOINT) || '|' || RDB$INPUT_SUB_TYPE || '|' || RDB$OUTPUT_SUB_TYPE || '|' || RDB$SYSTEM_FLAG || '|' || TRIM(RDB$OWNER_NAME) AS VARCHAR(60)) FROM RDB$FILTERS WHERE RDB$FUNCTION_NAME = 'F1'");
    readtext("SELECT CAST(COUNT(*) AS VARCHAR(5)) FROM RDB$FILTERS");
    exec("DECLARE FILTER F1 INPUT_TYPE 1 OUTPUT_TYPE 0 ENTRY_POINT 'x' MODULE_NAME 'y'");
    exec("DECLARE FILTER F3 INPUT_TYPE 1 OUTPUT_TYPE -5 ENTRY_POINT 'x' MODULE_NAME 'y'");
    exec("DROP FILTER NOPE");
    /* a declared filter with no module behind it: the conversion still has no filter to run */
    exec("INSERT INTO BC (ID, N) VALUES (8, 'abc')");
    exec("DROP FILTER F2");
    commit();
    readtext("SELECT CAST(COUNT(*) AS VARCHAR(5)) FROM RDB$FILTERS");
    exec("DROP FILTER F1");
    commit();
    readtext("SELECT CAST(COUNT(*) AS VARCHAR(5)) FROM RDB$FILTERS");
    isc_commit_transaction(st, &tr); isc_detach_database(st, &db);
    printf("done\n"); return 0;
}
