/* fbparamt <conn> <sql> <boundval> : bind ONE parameter as a
 * value-derived VARCHAR (exactly as node-firebird does) and read the
 * single output column in its NATIVE type - no server-side coercion, so
 * the server only has to send the slot it described. Prints the RAW
 * stored value (the ISC_DATE / ISC_TIME integer, the timestamp pair, or
 * the trimmed text), which is identical across two servers iff they
 * computed the same value. NULL / CONV_ERROR (22018) / OUT_OF_RANGE
 * (22003) / ERR <sqlstate> on the error paths. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ibase.h>
static void report(ISC_STATUS*st){
  char ss[8]; ss[0]=0; fb_sqlstate(ss, st);
  if(!strcmp(ss,"22018")) printf("CONV_ERROR\n");
  else if(!strcmp(ss,"22003")) printf("OUT_OF_RANGE\n");
  else printf("ERR %s\n", ss);
}
int main(int c,char**v){
  if(c<4){printf("usage: fbparamt <conn> <sql> <val>\n");return 2;}
  ISC_STATUS st[40]; isc_db_handle db=0; isc_tr_handle tr=0;
  char d[128]; short dl=0;
  d[dl++]=isc_dpb_version1;
  d[dl++]=isc_dpb_user_name; d[dl++]=6; memcpy(d+dl,"SYSDBA",6); dl+=6;
  d[dl++]=isc_dpb_password;  d[dl++]=9; memcpy(d+dl,"masterkey",9); dl+=9;
  if(isc_attach_database(st,0,v[1],&db,dl,d)){report(st);return 0;}
  isc_start_transaction(st,&tr,1,&db,0,NULL);
  isc_stmt_handle s=0; isc_dsql_allocate_statement(st,&db,&s);
  XSQLDA* out=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); out->version=SQLDA_VERSION1; out->sqln=1;
  if(isc_dsql_prepare(st,&tr,&s,0,v[2],3,out)){report(st);goto done;}
  int otype = out->sqlvar[0].sqltype & ~1;
  /* one input param, bound as value-derived VARCHAR (or NULL) */
  XSQLDA* in=(XSQLDA*)malloc(XSQLDA_LENGTH(1)); in->version=SQLDA_VERSION1; in->sqln=1;
  isc_dsql_describe_bind(st,&s,1,in);
  if(in->sqld!=1){printf("(expected 1 input param, got %d)\n",in->sqld);goto done;}
  int isnull = !strcmp(v[3],"NULL");
  short len=(short)strlen(v[3]); char buf[512]; *(short*)buf=len; memcpy(buf+2,v[3],len);
  short ind=isnull?-1:0;
  in->sqlvar[0].sqltype=SQL_VARYING+1; in->sqlvar[0].sqllen=len;
  in->sqlvar[0].sqldata=buf; in->sqlvar[0].sqlind=&ind;
  /* read the single output column NATIVELY (no coercion) */
  char ob[512]; short oind=0;
  out->sqlvar[0].sqltype |= 1;                 /* accept a NULL */
  out->sqlvar[0].sqldata=ob; out->sqlvar[0].sqlind=&oind;
  if(isc_dsql_execute(st,&tr,&s,1,in)){report(st);goto done;}
  long fr=isc_dsql_fetch(st,&s,1,out);
  if(fr==0){
    if(oind==-1){printf("NULL\n");}
    else switch(otype){
      case SQL_TYPE_DATE: printf("D:%d\n", *(ISC_DATE*)ob); break;
      case SQL_TYPE_TIME: printf("T:%u\n", *(ISC_TIME*)ob); break;
      case SQL_TIMESTAMP:{ ISC_TIMESTAMP*ts=(ISC_TIMESTAMP*)ob;
                           printf("TS:%d:%u\n", ts->timestamp_date, ts->timestamp_time); break; }
      case SQL_TEXT:{ char t[512]; int n=out->sqlvar[0].sqllen; memcpy(t,ob,n); t[n]=0;
                      while(n>0 && t[n-1]==' ') t[--n]=0; printf("S:%s\n", t); break; }
      case SQL_VARYING:{ short n=*(short*)ob; char t[512]; memcpy(t,ob+2,n); t[n]=0;
                         while(n>0 && t[n-1]==' ') t[--n]=0; printf("S:%s\n", t); break; }
      default: printf("type=%d\n", otype);
    }
  } else { printf("NOROW rc=%ld\n", fr); }
done:
  isc_rollback_transaction(st,&tr); isc_detach_database(st,&db); return 0;
}
