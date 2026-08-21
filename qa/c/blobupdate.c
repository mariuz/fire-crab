/* Blob PARAMETERS in UPDATE ... SET (and UPDATE OR INSERT): a temp blob
 * id passed as a ? to an UPDATE is materialised at the store (blb.cpp
 * blb::move), exactly like at an INSERT. The client walks the corner
 * cases - a blob beside an ordinary param, a NULL indicator, an all-zero
 * quad, one temp id feeding several rows, a text blob without a bpb, the
 * PERMANENT id of another row's blob as the param, UPDATE OR INSERT on an
 * existing and a new key, a rolled-back update, a temp id used after its
 * transaction committed - and prints one stable line per step. Every
 * line is compared against the engine's.
 *
 *   blobupdate <connection-string>
 */
#include <ibase.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static ISC_STATUS_ARRAY st;
static isc_db_handle db = 0;
static isc_tr_handle tr = 0;

static void errtext(char *out, size_t n) {
    char msg[512];
    const ISC_STATUS *p = st;
    out[0] = 0;
    while (fb_interpret(msg, sizeof msg, &p)) {
        size_t l = strlen(out);
        snprintf(out + l, n - l, "%s[%s]", l ? " " : "", msg);
    }
}
static void die(const char *what) {
    char e[1024]; errtext(e, sizeof e);
    printf("FAIL %s: %s\n", what, e);
    exit(1);
}
static void start(void) { if (isc_start_transaction(st, &tr, 1, &db, 0, NULL)) die("start"); }
static void commit(void) { if (isc_commit_transaction(st, &tr)) die("commit"); }
static void rollback(void) { if (isc_rollback_transaction(st, &tr)) die("rollback"); }

/* a temp blob holding the given text, in ONE segment (or two when len > 200) */
static ISC_QUAD make_blob(const char *text, const char *bpb, short bpblen) {
    isc_blob_handle bh = 0; ISC_QUAD id;
    if (isc_create_blob2(st, &db, &tr, &bh, &id, bpblen, bpb)) die("create_blob");
    int len = (int)strlen(text);
    if (len > 200) {
        if (isc_put_segment(st, &bh, 200, text)) die("put 1");
        if (isc_put_segment(st, &bh, (unsigned short)(len - 200), text + 200)) die("put 2");
    } else if (isc_put_segment(st, &bh, (unsigned short)len, text)) die("put");
    if (isc_close_blob(st, &bh)) die("close_blob");
    return id;
}

/* read a blob by id into buf (segments joined), return total length */
static int read_blob(ISC_QUAD *id, char *buf, int cap) {
    isc_blob_handle bh = 0; unsigned short got; int n = 0;
    if (isc_open_blob2(st, &db, &tr, &bh, id, 0, NULL)) { char e[1024]; errtext(e, sizeof e); snprintf(buf, cap, "<open error: %s>", e); return -1; }
    for (;;) {
        ISC_STATUS rc = isc_get_segment(st, &bh, &got, (unsigned short)(cap - 1 - n), buf + n);
        if (rc == 0 || rc == isc_segment) { n += got; if (n >= cap - 1) break; }
        else if (rc == isc_segstr_eof) break;
        else die("get_segment");
    }
    buf[n] = 0;
    isc_close_blob(st, &bh);
    return n;
}

/* execute a statement with up to 3 params; kinds: 'B' blob quad, 'I' int32, 'N' null blob, 'Z' all-zero quad.
 * prints "<tag>: ok" or "<tag>: error <text>" */
static void run(const char *tag, const char *sql, const char *kinds, ISC_QUAD *q0, ISC_QUAD *q1, int ival, int id0) {
    int np = (int)strlen(kinds);
    XSQLDA *in = (XSQLDA *)calloc(1, XSQLDA_LENGTH(np > 0 ? np : 1));
    in->version = SQLDA_VERSION1; in->sqln = np; in->sqld = np;
    short ind[3] = {0, 0, 0}; ISC_QUAD zero; memset(&zero, 0, sizeof zero);
    int ni = 0; for (const char *k = kinds; *k; k++) ni += (*k == 'I'); int ints[3]; ints[0] = ni == 2 ? id0 : ival; ints[1] = ival; ints[2] = ival;
    ISC_QUAD *qs[2] = { q0, q1 }; int qi = 0, ii = 0;
    for (int i = 0; i < np; i++) {
        XSQLVAR *v = &in->sqlvar[i]; v->sqlind = &ind[i];
        switch (kinds[i]) {
        case 'B': v->sqltype = SQL_BLOB + 1; v->sqllen = 8; v->sqldata = (char *)qs[qi++]; break;
        case 'N': v->sqltype = SQL_BLOB + 1; v->sqllen = 8; v->sqldata = (char *)&zero; ind[i] = -1; break;
        case 'Z': v->sqltype = SQL_BLOB + 1; v->sqllen = 8; v->sqldata = (char *)&zero; break;
        case 'I': v->sqltype = SQL_LONG + 1; v->sqllen = 4; v->sqldata = (char *)&ints[ii++]; break;
        }
    }
    isc_stmt_handle sth = 0;
    if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc");
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, NULL)) { char e[1024]; errtext(e, sizeof e); printf("%s: prepare error %s\n", tag, e); }
    else if (isc_dsql_execute(st, &tr, &sth, 1, np ? in : NULL)) { char e[1024]; errtext(e, sizeof e); printf("%s: error %s\n", tag, e); }
    else printf("%s: ok\n", tag);
    isc_dsql_free_statement(st, &sth, DSQL_drop);
    free(in);
}

/* SELECT N, SEG, TXT, OCTET_LENGTH(SEG), OCTET_LENGTH(TXT) FROM B WHERE ID = id; also yields the SEG id */
static void show(int id, ISC_QUAD *seg_out) {
    char sql[160];
    snprintf(sql, sizeof sql, "SELECT N, SEG, TXT, CAST(OCTET_LENGTH(SEG) AS INTEGER), CAST(OCTET_LENGTH(TXT) AS INTEGER) FROM B WHERE ID = %d", id);
    XSQLDA *out = (XSQLDA *)calloc(1, XSQLDA_LENGTH(5));
    out->version = SQLDA_VERSION1; out->sqln = 5;
    int n, ls, lt; ISC_QUAD seg, txt; short in_[5];
    isc_stmt_handle sth = 0;
    if (isc_dsql_allocate_statement(st, &db, &sth)) die("alloc sel");
    if (isc_dsql_prepare(st, &tr, &sth, 0, sql, 3, out)) die("prepare sel");
    out->sqlvar[0].sqltype = SQL_LONG + 1; out->sqlvar[0].sqldata = (char *)&n;
    out->sqlvar[1].sqltype = SQL_BLOB + 1; out->sqlvar[1].sqldata = (char *)&seg;
    out->sqlvar[2].sqltype = SQL_BLOB + 1; out->sqlvar[2].sqldata = (char *)&txt;
    out->sqlvar[3].sqltype = SQL_LONG + 1; out->sqlvar[3].sqldata = (char *)&ls;
    out->sqlvar[4].sqltype = SQL_LONG + 1; out->sqlvar[4].sqldata = (char *)&lt;
    for (int i = 0; i < 5; i++) out->sqlvar[i].sqlind = &in_[i];
    if (isc_dsql_execute(st, &tr, &sth, 1, NULL)) die("exec sel");
    ISC_STATUS rc = isc_dsql_fetch(st, &sth, 1, out);
    if (rc == 100) { printf("row %d: absent\n", id); }
    else if (rc) die("fetch sel");
    else {
        char bs[1024], bt[1024];
        printf("row %d:", id);
        if (in_[0] < 0) printf(" N=NULL"); else printf(" N=%d", n);
        if (in_[1] < 0) printf(" SEG=NULL"); else { read_blob(&seg, bs, sizeof bs); printf(" SEG='%s'", bs); }
        if (in_[3] < 0) printf(" len=NULL"); else printf(" len=%d", ls);
        if (in_[2] < 0) printf(" TXT=NULL"); else { read_blob(&txt, bt, sizeof bt); printf(" TXT='%s'", bt); }
        if (in_[4] < 0) printf(" tlen=NULL"); else printf(" tlen=%d", lt);
        printf("\n");
        if (seg_out) { if (in_[1] < 0) memset(seg_out, 0, sizeof *seg_out); else *seg_out = seg; }
    }
    isc_dsql_free_statement(st, &sth, DSQL_drop);
    free(out);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: blobupdate <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    char dpb[64]; int dl = 0;
    dpb[dl++] = isc_dpb_version1;
    dpb[dl++] = isc_dpb_user_name; dpb[dl++] = 6; memcpy(dpb + dl, "SYSDBA", 6); dl += 6;
    dpb[dl++] = isc_dpb_password; dpb[dl++] = 9; memcpy(dpb + dl, "masterkey", 9); dl += 9;
    /* no inline blobs: every read goes through op_open_blob2/op_get_segment on both sides */
    dpb[dl++] = isc_dpb_max_inline_blob_size; dpb[dl++] = 4; dpb[dl++] = 0; dpb[dl++] = 0; dpb[dl++] = 0; dpb[dl++] = 0;
    if (isc_attach_database(st, 0, argv[1], &db, (short)dl, dpb)) die("attach");
    ISC_QUAD q, q2;
    char bigbuf[320]; memset(bigbuf, 'u', 319); bigbuf[319] = 0; memcpy(bigbuf, "UPD1-", 5);

    /* seed as isql left it */
    start();
    for (int i = 1; i <= 4; i++) show(i, NULL);
    commit();

    /* 1. a new temp blob into SEG of row 1 (319 bytes, two segments) */
    start();
    q = make_blob(bigbuf, NULL, 0);
    run("s1 update seg row1", "UPDATE B SET SEG = ? WHERE ID = 1", "B", &q, NULL, 0, 0);
    show(1, NULL);
    commit();
    start(); printf("s1 after commit: "); show(1, NULL); commit();

    /* 2. blob param beside an ordinary one */
    start();
    q = make_blob("two-new", NULL, 0);
    run("s2 update seg+n row2", "UPDATE B SET SEG = ?, N = ? WHERE ID = 2", "BI", &q, NULL, 222, 0);
    commit();
    start(); show(2, NULL); commit();

    /* 3. NULL indicator */
    start();
    run("s3 update seg=null row3", "UPDATE B SET SEG = ? WHERE ID = 3", "N", NULL, NULL, 0, 0);
    commit();
    start(); show(3, NULL); commit();

    /* 4. an all-zero quad, no blob created */
    start();
    run("s4 update seg=zero-quad row4", "UPDATE B SET SEG = ? WHERE ID = 4", "Z", NULL, NULL, 0, 0);
    show(4, NULL);
    commit();
    start(); printf("s4 after commit: "); show(4, NULL); commit();

    /* 5. one temp blob id for several rows */
    start();
    q = make_blob("shared-by-many", NULL, 0);
    run("s5 update seg rows n>0", "UPDATE B SET SEG = ? WHERE N > 0", "B", &q, NULL, 0, 0);
    for (int i = 1; i <= 4; i++) show(i, NULL);
    commit();
    start(); printf("s5 after commit:\n"); for (int i = 1; i <= 4; i++) show(i, NULL); commit();

    /* 6. a text blob without bpb */
    start();
    q = make_blob("text-one-updated", NULL, 0);
    run("s6 update txt row1", "UPDATE B SET TXT = ? WHERE ID = 1", "B", &q, NULL, 0, 0);
    commit();
    start(); show(1, NULL); commit();

    /* 7. the PERMANENT id of row 2's SEG as the param for row 1 */
    start();
    show(2, &q2);
    run("s7 update seg row1 = row2's permanent id", "UPDATE B SET SEG = ? WHERE ID = 1", "B", &q2, NULL, 0, 0);
    show(1, NULL); show(2, NULL);
    commit();
    start(); printf("s7 after commit:\n"); show(1, NULL); show(2, NULL);
    /* is it the same blob id or a copy? */
    { ISC_QUAD a, b; show(1, &a); show(2, &b);
      printf("s7 ids: %s\n", (a.gds_quad_high == b.gds_quad_high && a.gds_quad_low == b.gds_quad_low) ? "same" : "different"); }
    commit();

    /* 7b. a row's OWN permanent id echoed back (a client writing every
       column on save): blb::move returns before copying when the ids are
       equal, so the id is kept */
    start();
    { ISC_QUAD own, after; show(1, &own);
      run("s7b update seg row1 = its own id", "UPDATE B SET SEG = ? WHERE ID = 1", "B", &own, NULL, 0, 0);
      show(1, &after);
      printf("s7b id kept: %s\n", (own.gds_quad_high == after.gds_quad_high && own.gds_quad_low == after.gds_quad_low) ? "yes" : "no"); }
    commit();
    start(); { ISC_QUAD own, after; show(1, &own); commit(); start(); show(1, &after);
      printf("s7b after commit id kept: %s\n", (own.gds_quad_high == after.gds_quad_high && own.gds_quad_low == after.gds_quad_low) ? "yes" : "no"); }
    commit();

    /* 8. UPDATE OR INSERT, existing key and new key */
    start();
    q = make_blob("upsert-existing", NULL, 0);
    run("s8 upsert id3", "UPDATE OR INSERT INTO B (ID, N, SEG) VALUES (?, ?, ?) MATCHING (ID)", "IIB", &q, NULL, 333, 3);
    q = make_blob("upsert-new", NULL, 0);
    run("s8 upsert id9", "UPDATE OR INSERT INTO B (ID, N, SEG) VALUES (?, ?, ?) MATCHING (ID)", "IIB", &q, NULL, 999, 9);
    commit();
    start(); show(3, NULL); show(9, NULL); commit();

    /* 9. rolled back */
    start();
    q = make_blob("rolled-back", NULL, 0);
    run("s9 update seg row2 then rollback", "UPDATE B SET SEG = ? WHERE ID = 2", "B", &q, NULL, 0, 0);
    show(2, NULL);
    rollback();
    start(); printf("s9 after rollback: "); show(2, NULL); commit();

    /* 10. a temp id after its transaction committed */
    start();
    q = make_blob("stale-temp", NULL, 0);
    commit();
    start();
    run("s10 update with stale temp id", "UPDATE B SET SEG = ? WHERE ID = 2", "B", &q, NULL, 0, 0);
    show(2, NULL);
    commit();
    /* and the same stale id in a rolled-back creating transaction */
    start();
    q = make_blob("stale-temp-rb", NULL, 0);
    rollback();
    start();
    run("s10b update with temp id of a rolled-back tx", "UPDATE B SET SEG = ? WHERE ID = 2", "B", &q, NULL, 0, 0);
    commit();

    start(); printf("final:\n"); show(1, NULL); show(2, NULL); show(3, NULL); show(4, NULL); show(9, NULL); commit();
    if (isc_detach_database(st, &db)) die("detach");
    printf("done\n");
    return 0;
}
