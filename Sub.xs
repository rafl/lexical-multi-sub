#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static SV *hintkey_sv_multi;
static SV *hintkey_sv_compiling_name;
static SV *hintkey_sv_compiling_sig;

#define keyword_active(hintkey_sv) S_keyword_active(aTHX_ hintkey_sv)
static int
S_keyword_active (pTHX_ SV *hintkey_sv)
{
    HE *he;

    if(!GvHV(PL_hintgv))
        return 0;

    he = hv_fetch_ent(GvHV(PL_hintgv), hintkey_sv, 0,
                      SvSHARED_HASH(hintkey_sv));

    return he && SvTRUE(HeVAL(he));
}

#define parse_idword(prefix) S_parse_idword(aTHX_ prefix)
static SV *
S_parse_idword (pTHX_ char const *prefix)
{
    STRLEN prefixlen, idlen;
    SV *sv;
    char *start, *s, c;

    s = start = PL_parser->bufptr;
    c = *s;

    if(!isIDFIRST(c)) {
        if (c == '(')
            croak("Anonymous multis not allowed");

        croak("syntax error");
    }

    do {
        c = *++s;
    } while (isALNUM(c));

    lex_read_to(s);
    prefixlen = strlen(prefix);
    idlen = s - start;
    sv = newSV(prefixlen + idlen);
    Copy(prefix, SvPVX(sv), prefixlen, char);
    Copy(start, SvPVX(sv) + prefixlen, idlen, char);
    SvPVX(sv)[prefixlen + idlen] = 0;
    SvCUR_set(sv, prefixlen + idlen);
    SvPOK_on(sv);

    return sv;
}

#define parse_signature() S_parse_signature(aTHX)
static SV *
S_parse_signature (pTHX)
{
    SV *sv;
    char *start, *s, c;

    if (lex_peek_unichar(0) != '(')
        croak("syntax error");
    lex_read_unichar(0);

    s = start = PL_parser->bufptr;
    c = *s;

    do {
        c = *++s;
    } while (c != ')');

    lex_read_to(s + 1);

    sv = newSVpvn(start, s - start);

    return sv;
}

#define analyse_signature(sv) S_analyse_signature(aTHX_ sv)
static SV *
S_analyse_signature (pTHX_ SV *sv)
{
    dSP;
    int count;
    SV *ret;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv);
    PUTBACK;

    count = call_pv("Lexical::Multi::Sub::_analyse_sig", G_SCALAR); /* G_EVAL? */

    if (count != 1)
        croak("uh oh");

    SPAGAIN;
    ret = SvREFCNT_inc(POPs);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return ret;
}

#define injectable_code(sig) S_injectable_code(aTHX_ sig)
static SV *
S_injectable_code(pTHX_ SV *sig)
{
    dSP;
    int count;
    SV *ret;

    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sig);
    PUTBACK;

    count = call_pv("Lexical::Multi::Sub::_injectable_code", G_SCALAR); /* G_EVAL? */

    if (count != 1)
        croak("uh oh");

    SPAGAIN;
    ret = SvREFCNT_inc(POPs);

    PUTBACK;
    FREETMPS;
    LEAVE;

    return ret;
}

#define parse_keyword_multi(op_ptr) S_parse_keyword_multi(aTHX_ op_ptr)
static int
S_parse_keyword_multi (pTHX_ OP **op_ptr)
{
    SV *namesv, *sigsv, *analysed_sig, *injectable_sig;

    lex_read_space(0);
    namesv = parse_idword("");

    lex_read_space(0);
    sigsv = parse_signature();

    analysed_sig = analyse_signature(sigsv);
    injectable_sig = injectable_code(analysed_sig);

    hv_store_ent(GvHV(PL_hintgv), hintkey_sv_compiling_name, namesv,
                 SvSHARED_HASH(hintkey_sv_compiling_name));
    hv_store_ent(GvHV(PL_hintgv), hintkey_sv_compiling_sig, analysed_sig,
                 SvSHARED_HASH(hintkey_sv_compiling_sig));

    lex_read_space(0);
    if (lex_peek_unichar(0) != '{')
        croak("syntax error");
    lex_read_unichar(0);

    lex_stuff_sv(injectable_sig, 0);
    lex_stuff_pvs("BEGIN{"
                  "Lexical::Multi::Sub::_register sub {"
                  "BEGIN{B::Hooks::EndOfScope::on_scope_end{"
                  "Lexical::Multi::Sub::_finish(\"};\");"
                  "}}",
                  0);
    lex_stuff_pvs(";", 0);
    lex_stuff_pvs("'}", 0);
    lex_stuff_sv(namesv, 0);
    lex_stuff_pvs("BEGIN{"
                  "Lexical::Multi::Sub::_declare '",
                  0);
    lex_stuff_pvs(";", 0);
    lex_stuff_sv(namesv, 0);
    lex_stuff_pvs("sub ", 0);
    lex_stuff_pvs(";", 0);

    *op_ptr = newOP(OP_NULL, 0);
    return KEYWORD_PLUGIN_STMT;
}

#define KEYWORD_IS(KW)                                  \
    (keyword_len == sizeof(""KW"") - 1 &&               \
     memEQ(keyword_ptr, ""KW"", sizeof(""KW"") - 1))

static int
multi_keyword_plugin (pTHX_ char *keyword_ptr, STRLEN keyword_len, OP **op_ptr)
{
    if (KEYWORD_IS("multi") && keyword_active(hintkey_sv_multi)) {
        return parse_keyword_multi(op_ptr);
    }

    return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
}

MODULE = Lexical::Multi::Sub  PACKAGE = Lexical::Multi::Sub

BOOT:
    hintkey_sv_multi = newSVpvs_share("Lexical::Multi::Sub/multi");
    hintkey_sv_compiling_name = newSVpvs_share("Lexical::Multi::Sub/compiling_name");
    hintkey_sv_compiling_sig = newSVpvs_share("Lexical::Multi::Sub/compiling_sig");
    next_keyword_plugin = PL_keyword_plugin;
    PL_keyword_plugin = multi_keyword_plugin;

void
_finish (SV *sv)
    PREINIT:
        HE *name;
    CODE:
        name = hv_fetch_ent(GvHV(PL_hintgv), hintkey_sv_compiling_name, 0,
			    SvSHARED_HASH(hintkey_sv_compiling_name));
        hv_delete_ent(PL_curstash, HeVAL(name), 0, 0);
        lex_stuff_sv(sv, 0);
