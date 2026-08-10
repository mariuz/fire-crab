/* fbparamj <conn> <sql> <projval> [whereval] : bind a projection `?`
 * (value-derived VARCHAR, as node-firebird sends it) and an optional
 * trailing WHERE `?` (a LONG), then read EVERY row as its integer output
 * columns joined by ','. One line per row, in fetch order, so a join /
 * grouped / derived projection param is a multi-row value differential
 * across two servers. Prints ERR <sqlstate> on the error paths. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void report(ISC_STATUS*st){ char ss[8]; ss[0]=0; fb_sqlstate(ss, st); printf("ERR %s\n", ss); }
int main(int c,char**v){
  if(c<4){printf("usage: fbparamj <conn> <sql> <projval> [whereval]\n");return 2;}
  ISC_STATUS st[40]; isc_db_handle db=0; isc_tr_handle tr=0;
  char d[128]; short dl=0;
  d[dl++]=isc_dpb_version1;
  d[dl++]=isc_dpb_user_name; d[dl++]=6; memcpy(d+dl,"SYSDBA",6); dl+=6;
  d[dl++]=isc_dpb_password;  d[dl++]=9; memcpy(d+dl,"masterkey",9); dl+=9;
  if(isc_attach_database(st,0,v[1],&db,dl,d)){report(st);return 0;}
  isc_start_transaction(st,&tr,1,&db,0,NULL);
  isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
  XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(16)); out->version=SQLDA_VERSION1; out->sqln=16;
  if(isc_dsql_prepare(st,&tr,&s,0,v[2],3,out)){report(st);goto done;}
  if(out->sqld>out->sqln){ out=(XSQLDA*)realloc(out,XSQLDA_LENGTH(out->sqld)); out->sqln=out->sqld; isc_dsql_describe(st,&s,1,out); }
  XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(4)); in->version=SQLDA_VERSION1; in->sqln=4;
  isc_dsql_describe_bind(st,&s,1,in);
  if(in->sqld>in->sqln){ in=(XSQLDA*)realloc(in,XSQLDA_LENGTH(in->sqld)); in->sqln=in->sqld; isc_dsql_describe_bind(st,&s,1,in); }
  printf("IN=%d OUT=%d\n", in->sqld, out->sqld);
  /* param 0 = value-derived VARCHAR from argv[3] */
  char pb[256]; short pl=(short)strlen(v[3]); *(short*)pb=pl; memcpy(pb+2,v[3],pl); short pn=0;
  if(in->sqld>=1){ in->sqlvar[0].sqltype=SQL_VARYING+1; in->sqlvar[0].sqllen=pl;
                   in->sqlvar[0].sqldata=pb; in->sqlvar[0].sqlind=&pn; }
  /* param 1 (optional) = LONG from argv[4] */
  long w=0; short wn=0;
  if(in->sqld>=2){ w=(c>4)?atol(v[4]):0;
                   in->sqlvar[1].sqltype=SQL_LONG+1; in->sqlvar[1].sqllen=4;
                   in->sqlvar[1].sqldata=(char*)&w; in->sqlvar[1].sqlind=&wn; }
  /* read each output column in its ANNOUNCED integer width (SHORT /
   * LONG / INT64) so there is NO server-side coercion in the middle -
   * an arithmetic column widens to INT64 and must be read as one */
  long long ov[16]; short oi[16]; int oty[16];
  for(int i=0;i<out->sqld && i<16;i++){
    oty[i]=out->sqlvar[i].sqltype & ~1;
    out->sqlvar[i].sqltype |= 1;                 /* accept a NULL */
    out->sqlvar[i].sqldata=(char*)&ov[i]; out->sqlvar[i].sqlind=&oi[i];
    ov[i]=0;
  }
  if(isc_dsql_execute(st,&tr,&s,1,in)){report(st);goto done;}
  long fr; int rows=0;
  while((fr=isc_dsql_fetch(st,&s,1,out))==0){
    for(int i=0;i<out->sqld && i<16;i++){
      if(i)printf(",");
      if(oi[i]==-1){ printf("NULL"); continue; }
      long long val;
      switch(oty[i]){
        case SQL_SHORT: val=*(short*)&ov[i]; break;
        case SQL_LONG:  val=*(int*)&ov[i]; break;
        case SQL_INT64: val=*(long long*)&ov[i]; break;
        default:        val=*(int*)&ov[i]; break;
      }
      printf("%lld", val);
    }
    printf("\n"); rows++;
  }
  if(fr!=100L) printf("FETCHERR rc=%ld\n", fr);
  if(rows==0) printf("(no rows)\n");
done:
  isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;
}
