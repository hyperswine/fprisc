/* Hosted byte encodings and SHA-256. No platform crypto library dependency.
 * SHA-256 follows the same schedule/rounds as std/digest.fpr, on uint32_t.
 * Contexts are private fixed-size copies; no pointers escape into Sol bytes. */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

typedef struct {
    uint32_t h[8];
    uint64_t total;
    size_t used;
    unsigned char pending[64];
} sol_sha256;

static uint32_t rotr(uint32_t x, unsigned n) { return (x >> n) | (x << (32-n)); }
static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0]<<24) | ((uint32_t)p[1]<<16) | ((uint32_t)p[2]<<8) | p[3];
}
static const uint32_t k[64] = {
    1116352408U,1899447441U,3049323471U,3921009573U,961987163U,1508970993U,2453635748U,2870763221U,
    3624381080U,310598401U,607225278U,1426881987U,1925078388U,2162078206U,2614888103U,3248222580U,
    3835390401U,4022224774U,264347078U,604807628U,770255983U,1249150122U,1555081692U,1996064986U,
    2554220882U,2821834349U,2952996808U,3210313671U,3336571891U,3584528711U,113926993U,338241895U,
    666307205U,773529912U,1294757372U,1396182291U,1695183700U,1986661051U,2177026350U,2456956037U,
    2730485921U,2820302411U,3259730800U,3345764771U,3516065817U,3600352804U,4094571909U,275423344U,
    430227734U,506948616U,659060556U,883997877U,958139571U,1322822218U,1537002063U,1747873779U,
    1955562222U,2024104815U,2227730452U,2361852424U,2428436474U,2756734187U,3204031479U,3329325298U
};
static void compress(sol_sha256 *s, const unsigned char *p) {
    uint32_t w[64];
    for (unsigned i=0;i<16;i++) w[i]=be32(p+4*i);
    for (unsigned i=16;i<64;i++) {
        uint32_t x=w[i-15], y=w[i-2];
        w[i]=w[i-16]+(rotr(x,7)^rotr(x,18)^(x>>3))+w[i-7]+(rotr(y,17)^rotr(y,19)^(y>>10));
    }
    uint32_t a=s->h[0],b=s->h[1],c=s->h[2],d=s->h[3],e=s->h[4],f=s->h[5],g=s->h[6],h=s->h[7];
    for (unsigned i=0;i<64;i++) {
        uint32_t t1=h+(rotr(e,6)^rotr(e,11)^rotr(e,25))+((e&f)^((~e)&g))+k[i]+w[i];
        uint32_t t2=(rotr(a,2)^rotr(a,13)^rotr(a,22))+((a&b)^(a&c)^(b&c));
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    s->h[0]+=a; s->h[1]+=b; s->h[2]+=c; s->h[3]+=d;
    s->h[4]+=e; s->h[5]+=f; s->h[6]+=g; s->h[7]+=h;
}
size_t sol_sha256_size(void) { return sizeof(sol_sha256); }
void sol_sha256_init(void *context) {
    static const uint32_t initial[8]={1779033703U,3144134277U,1013904242U,2773480762U,1359893119U,2600822924U,528734635U,1541459225U};
    sol_sha256 *s=context;
    memset(s,0,sizeof(*s)); memcpy(s->h,initial,sizeof(initial));
}
int sol_sha256_update(void *context, const unsigned char *p, size_t n) {
    sol_sha256 *s=context;
    if ((uint64_t)n > UINT64_MAX/8-s->total) return 1;
    s->total+=(uint64_t)n;
    if (s->used) {
        size_t take=64-s->used; if (take>n) take=n;
        memcpy(s->pending+s->used,p,take); s->used+=take; p+=take; n-=take;
        if (s->used==64) { compress(s,s->pending); s->used=0; }
    }
    while (n>=64) { compress(s,p); p+=64; n-=64; }
    if (n) { memcpy(s->pending,p,n); s->used=n; }
    return 0;
}
void sol_sha256_finish(void *context, unsigned char *out) {
    sol_sha256 *s=context;
    uint64_t bits=s->total*8;
    s->pending[s->used++]=128;
    if (s->used>56) { memset(s->pending+s->used,0,64-s->used); compress(s,s->pending); s->used=0; }
    memset(s->pending+s->used,0,56-s->used);
    for (unsigned i=0;i<8;i++) s->pending[63-i]=(unsigned char)(bits>>(i*8));
    compress(s,s->pending);
    for (unsigned i=0;i<8;i++) for (unsigned j=0;j<4;j++) out[4*i+j]=(unsigned char)(s->h[i]>>(24-8*j));
}

static const unsigned char hex[]="0123456789abcdef";
void sol_hex_encode(const unsigned char *in, size_t n, unsigned char *out) {
    for (size_t i=0;i<n;i++) { out[2*i]=hex[in[i]>>4]; out[2*i+1]=hex[in[i]&15]; }
}
static int unhex(unsigned char c) {
    if (c>='0'&&c<='9') return c-'0';
    if (c>='a'&&c<='f') return c-'a'+10;
    if (c>='A'&&c<='F') return c-'A'+10;
    return -1;
}
long long sol_hex_decode(const unsigned char *in, size_t n, unsigned char *out) {
    if (n%2) return -1;
    for (size_t i=0;i<n;i+=2) {
        int a=unhex(in[i]), b=unhex(in[i+1]);
        if (a<0||b<0) return -1;
        out[i/2]=(unsigned char)((a<<4)|b);
    }
    return (long long)(n/2);
}
static const unsigned char b64[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
void sol_base64_encode(const unsigned char *in, size_t n, unsigned char *out) {
    size_t i=0,j=0;
    while (i<n) {
        size_t left=n-i;
        uint32_t word=(uint32_t)in[i++]<<16;
        if (left>1) word|=(uint32_t)in[i++]<<8;
        if (left>2) word|=in[i++];
        out[j++]=b64[word>>18]; out[j++]=b64[(word>>12)&63];
        out[j++]=left>1?b64[(word>>6)&63]:'='; out[j++]=left>2?b64[word&63]:'=';
    }
}
static int unbase64(unsigned char c) {
    if (c>='A'&&c<='Z') return c-'A';
    if (c>='a'&&c<='z') return c-'a'+26;
    if (c>='0'&&c<='9') return c-'0'+52;
    if (c=='+') return 62;
    if (c=='/') return 63;
    return -1;
}
long long sol_base64_decode(const unsigned char *in, size_t n, unsigned char *out) {
    if (n%4) return -1;
    size_t j=0;
    for (size_t i=0;i<n;i+=4) {
        int a=unbase64(in[i]),b=unbase64(in[i+1]);
        int c=unbase64(in[i+2]),d=unbase64(in[i+3]);
        if (a<0||b<0) return -1;
        if (in[i+2]=='=') {
            if (i+4!=n || in[i+3]!='=' || (b&15)) return -1;
            out[j++]=(unsigned char)((a<<2)|(b>>4));
        } else if (in[i+3]=='=') {
            if (i+4!=n || c<0 || (c&3)) return -1;
            out[j++]=(unsigned char)((a<<2)|(b>>4)); out[j++]=(unsigned char)((b<<4)|(c>>2));
        } else {
            if (c<0||d<0) return -1;
            out[j++]=(unsigned char)((a<<2)|(b>>4)); out[j++]=(unsigned char)((b<<4)|(c>>2));
            out[j++]=(unsigned char)((c<<6)|d);
        }
    }
    return (long long)j;
}
