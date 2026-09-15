/* fbint64 <conn> <sql with one ?> <int64> [scale] : bind the ONE parameter
 * as a native SQL_INT64 (with the given decimal scale), exactly the value
 * the caller names - node-firebird cannot send an int64 past 2^53 without
 * rounding it through a double. Reads every row's first column as a LONG
 * and prints them joined by ';', "(none)" for no row, or "ERR | <status
 * lines>" on an error. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void report(ISC_STATUS*st){ const ISC_STATUS*p=st; char b[512]; printf("ERR"); while(fb_interpret(b,sizeof b,&p)) printf(" | %s", b); printf("\n"); }
int main(int c,char**v){
  if(c<4){printf("usage: fbint64 <conn> <sql> <int64> [scale]\n");return 2;}
  ISC_STATUS st[40]; isc_db_handle db=0; isc_tr_handle tr=0; char d[128]; short dl=0;
  d[dl++]=isc_dpb_version1;
  d[dl++]=isc_dpb_user_name; d[dl++]=6; memcpy(d+dl,"SYSDBA",6); dl+=6;
  d[dl++]=isc_dpb_password;  d[dl++]=9; memcpy(d+dl,"masterkey",9); dl+=9;
  if(isc_attach_database(st,0,v[1],&db,dl,d)){report(st);return 0;}
  isc_start_transaction(st,&tr,1,&db,0,NULL);
  isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
  XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); out->version=SQLDA_VERSION1; out->sqln=1;
  if(isc_dsql_prepare(st,&tr,&s,0,v[2],3,out)){report(st);goto done;}
  XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); in->version=SQLDA_VERSION1; in->sqln=1;
  isc_dsql_describe_bind(st,&s,1,in);
  if(in->sqld!=1){printf("(expected 1 input param, got %d)\n",in->sqld);goto done;}
  ISC_INT64 val=strtoll(v[3],0,10); short n=0;
  in->sqlvar[0].sqltype=SQL_INT64+1; in->sqlvar[0].sqllen=8;
  in->sqlvar[0].sqlscale=(c>4)?-atoi(v[4]):0;
  in->sqlvar[0].sqldata=(char*)&val; in->sqlvar[0].sqlind=&n;
  if(isc_dsql_execute(st,&tr,&s,1,in)){report(st);goto done;}
  { long x=0; short xi=0; int any=0; long fr;
    out->sqlvar[0].sqltype=SQL_LONG+1; out->sqlvar[0].sqllen=4;
    out->sqlvar[0].sqldata=(char*)&x; out->sqlvar[0].sqlind=&xi;
    while((fr=isc_dsql_fetch(st,&s,1,out))==0){ printf("%s%ld", any?";":"", x); any=1; }
    if(fr!=100) report(st); else printf("%s\n", any?"":"(none)"); }
done:
  isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;
}
