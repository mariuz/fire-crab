/* fbdesc <conn> <sql> : prepare and print the OUTPUT and INPUT describe
 * (sqltype, sqllen, sqlscale, sqlsubtype) - for measuring CAST(? AS T). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void warn(const char*w,ISC_STATUS*st){const ISC_STATUS*p=st;char b[512];printf("%s: ",w);while(fb_interpret(b,sizeof b,&p))printf("%s|",b);printf("\n");}
static void show(const char*tag,XSQLDA*x){
 printf("%s n=%d:",tag,x->sqld);
 for(int i=0;i<x->sqld && i<x->sqln;i++)
   printf(" [%d]type=%d len=%d scale=%d subtype=%d",i,x->sqlvar[i].sqltype&~1,x->sqlvar[i].sqllen,x->sqlvar[i].sqlscale,x->sqlvar[i].sqlsubtype);
 printf("\n");
}
int main(int c,char**v){ISC_STATUS st[40];isc_db_handle db=0;isc_tr_handle tr=0;
 char d[128];short dl=0;d[dl++]=isc_dpb_version1;d[dl++]=isc_dpb_user_name;d[dl++]=6;memcpy(d+dl,"SYSDBA",6);dl+=6;d[dl++]=isc_dpb_password;d[dl++]=9;memcpy(d+dl,"masterkey",9);dl+=9;
 if(isc_attach_database(st,0,v[1],&db,dl,d)){warn("att",st);return 2;}
 isc_start_transaction(st,&tr,1,&db,0,NULL);
 isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
 XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(4)); out->version=SQLDA_VERSION1; out->sqln=4;
 if(isc_dsql_prepare(st,&tr,&s,0,v[2],3,out)){warn("prep",st);return 0;}
 if(out->sqld>out->sqln){ out=(XSQLDA*)realloc(out,XSQLDA_LENGTH(out->sqld)); out->sqln=out->sqld; isc_dsql_describe(st,&s,1,out); }
 show("OUT",out);
 XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(4)); in->version=SQLDA_VERSION1; in->sqln=4;
 isc_dsql_describe_bind(st,&s,1,in);
 if(in->sqld>in->sqln){ in=(XSQLDA*)realloc(in,XSQLDA_LENGTH(in->sqld)); in->sqln=in->sqld; isc_dsql_describe_bind(st,&s,1,in); }
 show("IN ",in);
 isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;}
