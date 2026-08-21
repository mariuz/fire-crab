/* The ARRAY differential: isc_array_put_slice / isc_array_get_slice over
 * array columns, the ISC_ARRAY_DESC built by hand (the lookup helper
 * isc_array_lookup_bounds runs a catalog query through system packages
 * fire-crab does not have - recorded). A one-dimensional INTEGER array,
 * a two-dimensional DOUBLE array with a 0-based bound, a sub-slice read,
 * a read of a temp array before it is stored, and a table created
 * through the server under test (its own DDL). Each line is compared
 * with the engine's; in "engine-reads" mode only the reads run, against
 * the other server's file.
 *
 *   arrays <connection-string> [readonly]
 */
#include <ibase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ISC_STATUS_ARRAY st;
static isc_db_handle db = 0;
static isc_tr_handle tr = 0;

static void die(const char *what) {
    char msg[512]; const ISC_STATUS *p = st;
    printf("FAIL %s:", what);
    while (fb_interpret(msg, sizeof msg, &p)) printf(" [%s]", msg);
    printf("\n"); exit(1);
}
static const char *errtext(void) {
    static char msg[512]; const ISC_STATUS *p = st; msg[0] = 0;
    fb_interpret(msg, sizeof msg, &p);
    return msg;
}
static void exec(const char *sql) {
    if (isc_dsql_execute_immediate(st, &db, &tr, 0, sql, 3, NULL)) die(sql);
}
static void desc1(ISC_ARRAY_DESC *d, const char *rel, const char *fld, int dtype, int len, int lo, int hi) {
    memset(d, 0, sizeof *d);
    d->array_desc_dtype = dtype; d->array_desc_length = len; d->array_desc_scale = 0;
    strcpy(d->array_desc_field_name, fld); strcpy(d->array_desc_relation_name, rel);
    d->array_desc_dimensions = 1; d->array_desc_flags = 0;
    d->array_desc_bounds[0].array_bound_lower = lo; d->array_desc_bounds[0].array_bound_upper = hi;
}
static void desc2(ISC_ARRAY_DESC *d, const char *rel, const char *fld, int dtype, int len, int lo0, int hi0, int lo1, int hi1) {
    desc1(d, rel, fld, dtype, len, lo0, hi0);
    d->array_desc_dimensions = 2;
    d->array_desc_bounds[1].array_bound_lower = lo1; d->array_desc_bounds[1].array_bound_upper = hi1;
}
/* the array id of one row's column */
static int fetch_id(const char *sql, ISC_QUAD *id) {
    XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(1)); out->version = SQLDA_VERSION1; out->sqln = 1;
    short ind = 0; isc_stmt_handle sth = 0;
    if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, out)) die("prepare");
    out->sqlvar[0].sqldata = (char *)id; out->sqlvar[0].sqlind = &ind; out->sqlvar[0].sqltype = SQL_ARRAY + 1;
    if (isc_dsql_execute(st, &tr, &sth, 1, NULL)) die("execute");
    if (isc_dsql_fetch(st, &sth, 1, out)) die("fetch");
    isc_dsql_free_statement(st, &sth, DSQL_drop); free(out);
    return ind == 0;
}
static void show_ints(const char *tag, ISC_ARRAY_DESC *d, ISC_QUAD *id, int n) {
    int buf[64]; ISC_LONG len = n * 4; memset(buf, 0, sizeof buf);
    if (isc_array_get_slice(st, &db, &tr, id, d, buf, &len)) { printf("%s: get error %s\n", tag, errtext()); return; }
    printf("%s: len %ld:", tag, (long)len);
    for (int i = 0; i < n; i++) printf(" %d", buf[i]);
    printf("\n");
}
static void show_doubles(const char *tag, ISC_ARRAY_DESC *d, ISC_QUAD *id, int n) {
    double buf[64]; ISC_LONG len = n * 8; memset(buf, 0, sizeof buf);
    if (isc_array_get_slice(st, &db, &tr, id, d, buf, &len)) { printf("%s: get error %s\n", tag, errtext()); return; }
    printf("%s: len %ld:", tag, (long)len);
    for (int i = 0; i < n; i++) printf(" %.2f", buf[i]);
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: arrays <conn> [readonly]\n"); return 2; }
    int readonly = argc > 2 && strcmp(argv[2], "readonly") == 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    char dpb[64]; int dl = 0;
    dpb[dl++] = isc_dpb_version1;
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = 6; memcpy(dpb + dl, "SYSDBA", 6); dl += 6;
    dpb[dl++] = isc_dpb_password; dpb[dl++] = 9; memcpy(dpb + dl, "masterkey", 9); dl += 9;
    if (isc_attach_database(st, 0, argv[1], &db, (short)dl, dpb)) die("attach");
    if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start");
    ISC_ARRAY_DESC dv, dm; ISC_QUAD id;
    desc1(&dv, "AR", "V", blr_long, 4, 1, 5);
    desc2(&dm, "AR", "M", blr_double, 8, 0, 1, 1, 3);
    if (!readonly) {
        /* 1. a new INTEGER[1:5] array, stored by an INSERT */
        int v[5] = { 10, 20, 30, 40, 50 }; ISC_LONG len = sizeof v;
        memset(&id, 0, sizeof id);
        if (isc_array_put_slice(st, &db, &tr, &id, &dv, v, &len)) die("put V");
        printf("put V: len %ld, temp id %s\n", (long)len, (id.gds_quad_high == 0 && id.gds_quad_low == 0) ? "zero" : "set");
        show_ints("get V before store (temp)", &dv, &id, 5);
        {   XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(2)); in->version = SQLDA_VERSION1; in->sqln = 2; in->sqld = 2;
            int rid = 1; short i0 = 0, i1 = 0;
            in->sqlvar[0].sqltype = SQL_LONG; in->sqlvar[0].sqldata = (char *)&rid; in->sqlvar[0].sqllen = 4; in->sqlvar[0].sqlind = &i0;
            in->sqlvar[1].sqltype = SQL_ARRAY; in->sqlvar[1].sqldata = (char *)&id; in->sqlvar[1].sqllen = 8; in->sqlvar[1].sqlind = &i1;
            isc_stmt_handle sth = 0;
            if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
            if (isc_dsql_prepare(st, &tr, &sth, 0, "INSERT INTO AR (ID, V) VALUES (?, ?)", 3, NULL)) die("prepare insert");
            if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute insert");
            isc_dsql_free_statement(st, &sth, DSQL_drop); free(in);
        }
        /* 2. a DOUBLE[0:1, 1:3] array, 2-D, into row 2 */
        double m[2][3] = { { 1.5, 2.5, 3.5 }, { 4.5, 5.5, 6.5 } }; len = sizeof m;
        memset(&id, 0, sizeof id);
        if (isc_array_put_slice(st, &db, &tr, &id, &dm, m, &len)) die("put M");
        printf("put M: len %ld\n", (long)len);
        {   XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(2)); in->version = SQLDA_VERSION1; in->sqln = 2; in->sqld = 2;
            int rid = 2; short i0 = 0, i1 = 0;
            in->sqlvar[0].sqltype = SQL_LONG; in->sqlvar[0].sqldata = (char *)&rid; in->sqlvar[0].sqllen = 4; in->sqlvar[0].sqlind = &i0;
            in->sqlvar[1].sqltype = SQL_ARRAY; in->sqlvar[1].sqldata = (char *)&id; in->sqlvar[1].sqllen = 8; in->sqlvar[1].sqlind = &i1;
            isc_stmt_handle sth = 0;
            if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
            if (isc_dsql_prepare(st, &tr, &sth, 0, "INSERT INTO AR (ID, M) VALUES (?, ?)", 3, NULL)) die("prepare insert 2");
            if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute insert 2");
            isc_dsql_free_statement(st, &sth, DSQL_drop); free(in);
        }
        /* 3. a table created THROUGH this server, with a partial slice put */
        exec("CREATE TABLE AR2 (ID INTEGER NOT NULL PRIMARY KEY, W SMALLINT [2:4], NM VARCHAR(5))");
        if (isc_commit_retaining(st, &tr)) die("commit retaining");
        ISC_ARRAY_DESC dw; desc1(&dw, "AR2", "W", blr_short, 2, 3, 4);
        short w[2] = { 77, 88 }; len = sizeof w; memset(&id, 0, sizeof id);
        if (isc_array_put_slice(st, &db, &tr, &id, &dw, w, &len)) die("put W");
        printf("put W (elements 3..4 of 2..4): len %ld\n", (long)len);
        {   XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(2)); in->version = SQLDA_VERSION1; in->sqln = 2; in->sqld = 2;
            int rid = 7; short i0 = 0, i1 = 0;
            in->sqlvar[0].sqltype = SQL_LONG; in->sqlvar[0].sqldata = (char *)&rid; in->sqlvar[0].sqllen = 4; in->sqlvar[0].sqlind = &i0;
            in->sqlvar[1].sqltype = SQL_ARRAY; in->sqlvar[1].sqldata = (char *)&id; in->sqlvar[1].sqllen = 8; in->sqlvar[1].sqlind = &i1;
            isc_stmt_handle sth = 0;
            if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
            if (isc_dsql_prepare(st, &tr, &sth, 0, "INSERT INTO AR2 (ID, W, NM) VALUES (?, ?, 'seven')", 3, NULL)) die("prepare insert 3");
            if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute insert 3");
            isc_dsql_free_statement(st, &sth, DSQL_drop); free(in);
        }
        /* 4. NUMERIC(9,2)[1:3] and CHAR(4)[1:2] elements, a BIGINT[0:1]; an ALTER ADD array */
        exec("CREATE TABLE AN (ID INTEGER NOT NULL PRIMARY KEY, N NUMERIC(9,2) [1:3], C CHAR(4) [1:2], B BIGINT [0:1])");
        exec("ALTER TABLE AR2 ADD Z SMALLINT [1:2]");
        if (isc_commit_retaining(st, &tr)) die("commit retaining 2");
        {   ISC_ARRAY_DESC dn, dc, dbg, dz; ISC_QUAD qn, qc, qb, qz;
            desc1(&dn, "AN", "N", blr_long, 4, 1, 3); dn.array_desc_scale = -2;
            desc1(&dc, "AN", "C", blr_text, 4, 1, 2);
            desc1(&dbg, "AN", "B", blr_int64, 8, 0, 1);
            desc1(&dz, "AR2", "Z", blr_short, 2, 1, 2);
            int n[3] = { 1234, -250, 99999 }; char c[2][4] = { "abcd", "ef  " }; ISC_INT64 bg[2] = { 5000000000LL, -7 }; short z[2] = { 9, -9 };
            len = sizeof n; memset(&qn, 0, 8); if (isc_array_put_slice(st, &db, &tr, &qn, &dn, n, &len)) die("put N"); printf("put N: len %ld\n", (long)len);
            len = sizeof c; memset(&qc, 0, 8); if (isc_array_put_slice(st, &db, &tr, &qc, &dc, c, &len)) die("put C"); printf("put C: len %ld\n", (long)len);
            len = sizeof bg; memset(&qb, 0, 8); if (isc_array_put_slice(st, &db, &tr, &qb, &dbg, bg, &len)) die("put B"); printf("put B: len %ld\n", (long)len);
            len = sizeof z; memset(&qz, 0, 8); if (isc_array_put_slice(st, &db, &tr, &qz, &dz, z, &len)) die("put Z"); printf("put Z: len %ld\n", (long)len);
            XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(3)); in->version = SQLDA_VERSION1; in->sqln = 3; in->sqld = 3;
            short i0 = 0, i1 = 0, i2 = 0;
            in->sqlvar[0].sqltype = SQL_ARRAY; in->sqlvar[0].sqldata = (char *)&qn; in->sqlvar[0].sqllen = 8; in->sqlvar[0].sqlind = &i0;
            in->sqlvar[1].sqltype = SQL_ARRAY; in->sqlvar[1].sqldata = (char *)&qc; in->sqlvar[1].sqllen = 8; in->sqlvar[1].sqlind = &i1;
            in->sqlvar[2].sqltype = SQL_ARRAY; in->sqlvar[2].sqldata = (char *)&qb; in->sqlvar[2].sqllen = 8; in->sqlvar[2].sqlind = &i2;
            isc_stmt_handle sth = 0;
            if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
            if (isc_dsql_prepare(st, &tr, &sth, 0, "INSERT INTO AN (ID, N, C, B) VALUES (1, ?, ?, ?)", 3, NULL)) die("prepare insert AN");
            if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute insert AN");
            isc_dsql_free_statement(st, &sth, DSQL_drop); free(in);
            in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(1)); in->version = SQLDA_VERSION1; in->sqln = 1; in->sqld = 1;
            in->sqlvar[0].sqltype = SQL_ARRAY; in->sqlvar[0].sqldata = (char *)&qz; in->sqlvar[0].sqllen = 8; in->sqlvar[0].sqlind = &i0;
            sth = 0;
            if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
            if (isc_dsql_prepare(st, &tr, &sth, 0, "UPDATE AR2 SET Z = ? WHERE ID = 7", 3, NULL)) die("prepare update Z");
            if (isc_dsql_execute(st, &tr, &sth, 1, in)) die("execute update Z");
            isc_dsql_free_statement(st, &sth, DSQL_drop); free(in);
        }
        if (isc_commit_transaction(st, &tr)) die("commit");
        if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start 2");
    }
    /* reads */
    if (fetch_id("SELECT V FROM AR WHERE ID = 1", &id)) show_ints("V of row 1", &dv, &id, 5); else printf("V of row 1: null\n");
    {   ISC_ARRAY_DESC sub = dv; sub.array_desc_bounds[0].array_bound_lower = 2; sub.array_desc_bounds[0].array_bound_upper = 4;
        show_ints("V[2:4] of row 1", &sub, &id, 3); }
    if (fetch_id("SELECT M FROM AR WHERE ID = 2", &id)) show_doubles("M of row 2", &dm, &id, 6); else printf("M of row 2: null\n");
    {   ISC_ARRAY_DESC sub = dm; sub.array_desc_bounds[0].array_bound_lower = 1; sub.array_desc_bounds[0].array_bound_upper = 1;
        show_doubles("M[1][1:3] of row 2", &sub, &id, 3); }
    if (fetch_id("SELECT V FROM AR WHERE ID = 2", &id)) show_ints("V of row 2", &dv, &id, 5); else printf("V of row 2: null\n");
    {   ISC_ARRAY_DESC dw; desc1(&dw, "AR2", "W", blr_short, 2, 2, 4);
        if (fetch_id("SELECT W FROM AR2 WHERE ID = 7", &id)) {
            short buf[3] = { -1, -1, -1 }; ISC_LONG len = sizeof buf;
            if (isc_array_get_slice(st, &db, &tr, &id, &dw, buf, &len)) printf("W of row 7: get error %s\n", errtext());
            else printf("W of row 7: len %ld: %d %d %d\n", (long)len, buf[0], buf[1], buf[2]);
        } else printf("W of row 7: null\n"); }
    /* the CLIENT's own catalog lookup - isc_array_lookup_bounds runs the
       search-path CTE (row_number() over a parse_unqualified_names derived
       table, joined to system.rdb$relation_fields / rdb$fields /
       rdb$field_dimensions) over the wire */
    {   const char *lk[][2] = { { "AN", "N" }, { "AN", "C" }, { "AR", "M" }, { "AR2", "Z" }, { "AR", "NOPE" } };
        for (int i = 0; i < 5; i++) {
            ISC_ARRAY_DESC ld; memset(&ld, 0, sizeof ld);
            if (isc_array_lookup_bounds(st, &db, &tr, (char *)lk[i][0], (char *)lk[i][1], &ld)) { printf("lookup %s.%s: error %s\n", lk[i][0], lk[i][1], errtext()); continue; }
            printf("lookup %s.%s: dtype %d scale %d length %d dims %d [%d:%d]", lk[i][0], lk[i][1], ld.array_desc_dtype, ld.array_desc_scale, ld.array_desc_length, ld.array_desc_dimensions, ld.array_desc_bounds[0].array_bound_lower, ld.array_desc_bounds[0].array_bound_upper);
            if (ld.array_desc_dimensions > 1) printf(" [%d:%d]", ld.array_desc_bounds[1].array_bound_lower, ld.array_desc_bounds[1].array_bound_upper);
            printf("\n");
        }
    }
    /* the NUMERIC / CHAR / BIGINT / ALTER-added arrays, and element CONVERSION */
    {   ISC_ARRAY_DESC dn, dc, dbg, dz; ISC_QUAD q;
        desc1(&dn, "AN", "N", blr_long, 4, 1, 3); dn.array_desc_scale = -2;
        desc1(&dc, "AN", "C", blr_text, 4, 1, 2);
        desc1(&dbg, "AN", "B", blr_int64, 8, 0, 1);
        desc1(&dz, "AR2", "Z", blr_short, 2, 1, 2);
        if (fetch_id("SELECT N FROM AN WHERE ID = 1", &q)) {
            show_ints("N (scaled longs) of AN 1", &dn, &q, 3);
            ISC_ARRAY_DESC asd = dn; asd.array_desc_dtype = blr_double; asd.array_desc_length = 8; asd.array_desc_scale = 0;
            show_doubles("N read as DOUBLE", &asd, &q, 3);
            ISC_ARRAY_DESC ass = dn; ass.array_desc_dtype = blr_short; ass.array_desc_length = 2; ass.array_desc_scale = 0;
            { short buf[3] = { 0, 0, 0 }; ISC_LONG len = sizeof buf;
              if (isc_array_get_slice(st, &db, &tr, &q, &ass, buf, &len)) printf("N read as SMALLINT scale 0: get error %s\n", errtext());
              else printf("N read as SMALLINT scale 0: len %ld: %d %d %d\n", (long)len, buf[0], buf[1], buf[2]); }
        } else printf("N of AN 1: null\n");
        if (fetch_id("SELECT C FROM AN WHERE ID = 1", &q)) {
            char buf[2][4]; ISC_LONG len = sizeof buf; memset(buf, 0, sizeof buf);
            if (isc_array_get_slice(st, &db, &tr, &q, &dc, buf, &len)) printf("C of AN 1: get error %s\n", errtext());
            else printf("C of AN 1: len %ld: '%.4s' '%.4s'\n", (long)len, buf[0], buf[1]);
        } else printf("C of AN 1: null\n");
        if (fetch_id("SELECT B FROM AN WHERE ID = 1", &q)) {
            ISC_INT64 buf[2] = { 0, 0 }; ISC_LONG len = sizeof buf;
            if (isc_array_get_slice(st, &db, &tr, &q, &dbg, buf, &len)) printf("B of AN 1: get error %s\n", errtext());
            else printf("B of AN 1: len %ld: %lld %lld\n", (long)len, (long long)buf[0], (long long)buf[1]);
            ISC_ARRAY_DESC asl = dbg; asl.array_desc_dtype = blr_long; asl.array_desc_length = 4;
            { int ib[2] = { 0, 0 }; ISC_LONG l2 = sizeof ib;
              if (isc_array_get_slice(st, &db, &tr, &q, &asl, ib, &l2)) printf("B read as INTEGER (overflow): get error %s\n", errtext());
              else printf("B read as INTEGER (overflow): len %ld: %d %d\n", (long)l2, ib[0], ib[1]); }
        } else printf("B of AN 1: null\n");
        if (fetch_id("SELECT Z FROM AR2 WHERE ID = 7", &q)) {
            short buf[2] = { 0, 0 }; ISC_LONG len = sizeof buf;
            if (isc_array_get_slice(st, &db, &tr, &q, &dz, buf, &len)) printf("Z of AR2 7 (ALTER-added): get error %s\n", errtext());
            else printf("Z of AR2 7 (ALTER-added): len %ld: %d %d\n", (long)len, buf[0], buf[1]);
        } else printf("Z of AR2 7: null\n");
        if (fetch_id("SELECT V FROM AR WHERE ID = 1", &q)) {
            ISC_ARRAY_DESC asd = dv; asd.array_desc_dtype = blr_double; asd.array_desc_length = 8;
            show_doubles("V read as DOUBLE", &asd, &q, 5);
            ISC_ARRAY_DESC ass = dv; ass.array_desc_dtype = blr_short; ass.array_desc_length = 2;
            { short buf[5]; ISC_LONG len = sizeof buf; memset(buf, 0, sizeof buf);
              if (isc_array_get_slice(st, &db, &tr, &q, &ass, buf, &len)) printf("V read as SMALLINT: get error %s\n", errtext());
              else printf("V read as SMALLINT: len %ld: %d %d %d %d %d\n", (long)len, buf[0], buf[1], buf[2], buf[3], buf[4]); }
        }
    }
    if (isc_commit_transaction(st, &tr)) die("commit 2");
    if (isc_detach_database(st, &db)) die("detach");
    printf("done\n");
    return 0;
}
