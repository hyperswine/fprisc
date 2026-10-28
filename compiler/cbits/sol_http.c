/* libcurl is called only by the isolated sol-http-worker process. The parent
 * owns/kills/reaps that process group, including during a blocked DNS lookup. */
#include <curl/curl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    FILE *body, *headers;
    uint64_t body_size, header_size, body_limit, header_limit;
    int fault; /* 5 body/header budget, 8 file I/O */
    const char *detail;
} sol_http_sink;

static size_t sink_write(char *p, size_t size, size_t count, void *user) {
    sol_http_sink *s=user;
    if (size && count>SIZE_MAX/size) { s->fault=5; s->detail="body byte limit exceeded"; return 0; }
    size_t n=size*count;
    if ((uint64_t)n>s->body_limit-s->body_size) { s->fault=5; s->detail="body byte limit exceeded"; return 0; }
    if (fwrite(p,1,n,s->body)!=n) { s->fault=8; s->detail="response body write failed"; return 0; }
    s->body_size+=(uint64_t)n;
    return n;
}
static size_t sink_header(char *p, size_t size, size_t count, void *user) {
    sol_http_sink *s=user;
    if (size && count>SIZE_MAX/size) { s->fault=5; s->detail="header byte limit exceeded"; return 0; }
    size_t n=size*count;
    if ((uint64_t)n>s->header_limit-s->header_size) { s->fault=5; s->detail="header byte limit exceeded"; return 0; }
    if (fwrite(p,1,n,s->headers)!=n) { s->fault=8; s->detail="response header write failed"; return 0; }
    s->header_size+=(uint64_t)n;
    return n;
}
int sol_http_available(void) {
    curl_version_info_data *v=curl_version_info(CURLVERSION_NOW);
    if (!v || v->version_num<0x080400 || !(v->features&CURL_VERSION_SSL)) return 0;
    int http=0,https=0;
    for (const char *const *p=v->protocols;p && *p;p++) {
        if (!strcmp(*p,"http")) http=1;
        if (!strcmp(*p,"https")) https=1;
    }
    return http&&https;
}
const char *sol_http_version(void) { return curl_version(); }

/* Input header/resolve entries are separately validated UTF-8 strings. Lists
 * use one entry per line; CR/LF/NUL are refused by the parent and worker. */
static struct curl_slist *line_list(const char *text, int *failed) {
    struct curl_slist *list=NULL;
    while (*text) {
        size_t n=strcspn(text,"\n");
        char *line=malloc(n+1);
        if (!line) { *failed=1; break; }
        memcpy(line,text,n); line[n]=0;
        struct curl_slist *next=curl_slist_append(list,line);
        free(line);
        if (!next) { *failed=1; break; }
        list=next; text+=n; if (*text=='\n') text++;
    }
    return list;
}

/* Returns a stable category, plus libcurl status, HTTP status, byte count and
 * bounded diagnostic. Automatic redirects are allowed only for GET/HEAD by
 * the caller. TLS peer/hostname verification has no disabling option. */
int sol_http_request(const char *url, const char *method, const char *request_headers,
    const unsigned char *body, size_t body_length, long deadline_ms,
    uint64_t body_limit, uint64_t header_limit, long redirects, int allow_http,
    const char *ca_file, const char *routes, const char *body_path, const char *header_path,
    long *status, uint64_t *bytes, long *curl_code, char *message, size_t message_size) {
    sol_http_sink sink={0};
    sink.body_limit=body_limit; sink.header_limit=header_limit;
    CURL *easy=NULL;
    struct curl_slist *headers=NULL,*resolve=NULL;
    CURLcode code=CURLE_OK;
    int reason=0,failed=0;
    char error[CURL_ERROR_SIZE]={0};
    *status=0; *bytes=0; *curl_code=0;
    if (!sol_http_available()) { reason=2; snprintf(message,message_size,"libcurl >= 8.4 with HTTP/HTTPS and TLS is required"); goto done; }
    if (curl_global_init(CURL_GLOBAL_DEFAULT)!=CURLE_OK) { reason=2; snprintf(message,message_size,"libcurl initialization failed"); goto done; }
    easy=curl_easy_init();
    if (!easy) { reason=2; snprintf(message,message_size,"libcurl handle allocation failed"); goto done; }
    sink.body=fopen(body_path,"wb"); sink.headers=fopen(header_path,"wb");
    if (!sink.body || !sink.headers) { reason=8; snprintf(message,message_size,"response staging open failed: %s",strerror(errno)); goto done; }
    headers=line_list(request_headers,&failed); resolve=line_list(routes,&failed);
    if (failed) { reason=8; snprintf(message,message_size,"request list allocation failed"); goto done; }
#define SET(option,value) do { code=curl_easy_setopt(easy,option,value); if (code!=CURLE_OK) goto transfer_done; } while(0)
    SET(CURLOPT_ERRORBUFFER,error);
    SET(CURLOPT_URL,url);
    SET(CURLOPT_PROTOCOLS_STR,"http,https");
    SET(CURLOPT_REDIR_PROTOCOLS_STR,allow_http?"http,https":"https");
    SET(CURLOPT_FOLLOWLOCATION,redirects>=0?1L:0L);
    SET(CURLOPT_MAXREDIRS,redirects>=0?redirects:0L);
    SET(CURLOPT_TIMEOUT_MS,deadline_ms);
    SET(CURLOPT_CONNECTTIMEOUT_MS,deadline_ms);
    SET(CURLOPT_NOSIGNAL,1L);
    SET(CURLOPT_SSL_VERIFYPEER,1L);
    SET(CURLOPT_SSL_VERIFYHOST,2L);
    SET(CURLOPT_NETRC,(long)CURL_NETRC_IGNORED);
    SET(CURLOPT_PROXY,""); /* no ambient proxy/config/credentials */
    SET(CURLOPT_HTTPHEADER,headers);
    SET(CURLOPT_RESOLVE,resolve);
    if (*ca_file) SET(CURLOPT_CAINFO,ca_file);
    SET(CURLOPT_WRITEFUNCTION,sink_write); SET(CURLOPT_WRITEDATA,&sink);
    SET(CURLOPT_HEADERFUNCTION,sink_header); SET(CURLOPT_HEADERDATA,&sink);
    if (body_limit) SET(CURLOPT_MAXFILESIZE_LARGE,(curl_off_t)body_limit);
    if (!strcmp(method,"HEAD")) SET(CURLOPT_NOBODY,1L);
    else if (body_length || !strcmp(method,"POST") || !strcmp(method,"PUT") || !strcmp(method,"PATCH")) {
        SET(CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)body_length);
        SET(CURLOPT_POSTFIELDS,body_length?(const char *)body:"");
    }
    SET(CURLOPT_CUSTOMREQUEST,method);
    code=curl_easy_perform(easy);
transfer_done:
    curl_easy_getinfo(easy,CURLINFO_RESPONSE_CODE,status);
    *curl_code=(long)code; *bytes=sink.body_size;
    if (sink.fault) { reason=sink.fault; snprintf(message,message_size,"%s",sink.detail); }
    else if (code==CURLE_OPERATION_TIMEDOUT) reason=4;
    else if (code==CURLE_FILESIZE_EXCEEDED) reason=5;
    else if (code==CURLE_TOO_MANY_REDIRECTS || code==CURLE_UNSUPPORTED_PROTOCOL) reason=6;
    else if (code==CURLE_PEER_FAILED_VERIFICATION || code==CURLE_SSL_CONNECT_ERROR || code==CURLE_SSL_CACERT_BADFILE || code==CURLE_SSL_CERTPROBLEM
             || code==CURLE_SSL_ISSUER_ERROR || code==CURLE_SSL_CRL_BADFILE || code==CURLE_SSL_PINNEDPUBKEYNOTMATCH || code==CURLE_SSL_INVALIDCERTSTATUS || code==CURLE_SSL_CLIENTCERT) reason=3;
    else if (code!=CURLE_OK) reason=7;
    if (reason && !*message) snprintf(message,message_size,"%s",*error?error:curl_easy_strerror(code));
done:
    if (sink.body && fclose(sink.body)!=0 && !reason) { reason=8; snprintf(message,message_size,"response body flush/close failed"); }
    if (sink.headers && fclose(sink.headers)!=0 && !reason) { reason=8; snprintf(message,message_size,"response header flush/close failed"); }
    if (easy) curl_easy_cleanup(easy);
    curl_slist_free_all(headers); curl_slist_free_all(resolve);
    curl_global_cleanup();
    return reason;
}
