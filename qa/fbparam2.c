/* fbparam2 <conn> : SELECT CAST(? AS INTEGER), X FROM T WHERE X = ?
 * bind proj param 0 = '2.5' (text), where param 1 = 7 (int). Print the
 * two input describe types (in order) and the fetched CAST value. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void err(const char*w,ISC_STATUS*st){const ISC_STATUS*p=st;char b[512];printf("%s: ",w);while(fb_interpret(b,sizeof b,&p))printf("%s|",b);printf("\n");}
int main(int c,char**v){ISC_STATUS st[40];isc_db_handle db=0;isc_tr_handle tr=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&db,dl,d)){err("att",st);return 2;}
 isc_start_transaction(st,&tr,1,&db,0,NULL);
 isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
 const char* sql="SELECT CAST(? AS INTEGER), X FROM T WHERE X = ?";
 XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(2)); out->version=SQLDA_VERSION1; out->sqln=2;
 if(isc_dsql_prepare(st,&tr,&s,0,sql,3,out)){err("prep",st);return 0;}
 XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(2)); in->version=SQLDA_VERSION1; in->sqln=2;
 isc_dsql_describe_bind(st,&s,1,in);
 printf("IN count=%d: [0]=%d [1]=%d\n", in->sqld, in->sqld>0?in->sqlvar[0].sqltype&~1:0, in->sqld>1?in->sqlvar[1].sqltype&~1:0);
 if(in->sqld!=2){printf("(expected 2 input params)\n");goto done;}
 /* param 0: CAST target = INTEGER slot, but send value-derived VARCHAR '2.5' */
 char b0[64]; short l0=3; *(short*)b0=l0; memcpy(b0+2,"2.5",3); short n0=0;
 in->sqlvar[0].sqltype=SQL_VARYING+1; in->sqlvar[0].sqllen=l0; in->sqlvar[0].sqldata=b0; in->sqlvar[0].sqlind=&n0;
 /* param 1: WHERE X = 7 */
 long w=7; short n1=0;
 in->sqlvar[1].sqltype=SQL_LONG+1; in->sqlvar[1].sqllen=4; in->sqlvar[1].sqldata=(char*)&w; in->sqlvar[1].sqlind=&n1;
 if(isc_dsql_execute2(st,&tr,&s,1,in,NULL)){err("exec",st);goto done;}
 { long i32=0, x=0; short oi=0, xi=0;
   out->sqlvar[0].sqltype=SQL_LONG+1; out->sqlvar[0].sqllen=4; out->sqlvar[0].sqldata=(char*)&i32; out->sqlvar[0].sqlind=&oi;
   out->sqlvar[1].sqltype=SQL_LONG+1; out->sqlvar[1].sqllen=4; out->sqlvar[1].sqldata=(char*)&x; out->sqlvar[1].sqlind=&xi;
   long fr=isc_dsql_fetch(st,&s,1,out);
   if(fr==0) printf("ROW: cast=%ld x=%ld\n", i32, x); else printf("NOROW rc=%ld\n",fr); }
done:
 isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;}
