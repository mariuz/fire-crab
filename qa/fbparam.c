/* fbparam <conn> <sql> <textval|NULL> : prepare a one-`?` projection,
 * bind the value as VARCHAR (value-derived, as node-firebird does), read
 * the output PER ITS ANNOUNCED TYPE (SHORT/LONG/INT64 - fire-crab and the
 * engine now announce the same, so this is describe-faithful and still
 * value-comparable), and print the value or the error class. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void err(ISC_STATUS*st){const ISC_STATUS*p=st;char b[512];
 while(fb_interpret(b,sizeof b,&p)){
   if(strstr(b,"out of range")){printf("OUT_OF_RANGE\n");return;}
   if(strstr(b,"onversion error")){printf("CONV_ERROR\n");return;}
 }
 printf("ERR %ld\n",(long)st[1]);}
int main(int c,char**v){ISC_STATUS st[40];isc_db_handle db=0;isc_tr_handle tr=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&db,dl,d)){err(st);return 2;}
 isc_start_transaction(st,&tr,1,&db,0,NULL);
 isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
 XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); out->version=SQLDA_VERSION1; out->sqln=1;
 if(isc_dsql_prepare(st,&tr,&s,0,v[2],3,out)){err(st);return 0;}
 XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); in->version=SQLDA_VERSION1; in->sqln=1;
 isc_dsql_describe_bind(st,&s,1,in);
 short nf = (strcmp(v[3],"NULL")==0) ? -1 : 0;
 char buf[256]; short len=(short)strlen(v[3]); *(short*)buf=len; memcpy(buf+2,v[3],len);
 in->sqlvar[0].sqltype=SQL_VARYING+1; in->sqlvar[0].sqllen=len; in->sqlvar[0].sqldata=buf; in->sqlvar[0].sqlind=&nf;
 /* read the OUTPUT per its announced base type */
 short base = out->sqlvar[0].sqltype & ~1;
 short i16=0; long i32=0; ISC_INT64 i64=0; short oind=0;
 out->sqlvar[0].sqlind=&oind;
 if(base==SQL_SHORT){ out->sqlvar[0].sqltype=SQL_SHORT+1; out->sqlvar[0].sqldata=(char*)&i16; }
 else if(base==SQL_LONG){ out->sqlvar[0].sqltype=SQL_LONG+1; out->sqlvar[0].sqldata=(char*)&i32; }
 else { out->sqlvar[0].sqltype=SQL_INT64+1; out->sqlvar[0].sqllen=8; out->sqlvar[0].sqldata=(char*)&i64; }
 if(isc_dsql_execute2(st,&tr,&s,1,in,NULL)){err(st);goto done;}
 { long fr=isc_dsql_fetch(st,&s,1,out);
   if(fr==0){
     if(oind) printf("NULL\n");
     else if(base==SQL_SHORT) printf("%d\n",i16);
     else if(base==SQL_LONG) printf("%ld\n",i32);
     else printf("%lld\n",(long long)i64);
   }
   else if(fr==100) printf("NOROW\n");
   else err(st); }
done:
 isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;}
