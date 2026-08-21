// The scrollable-cursor differential: one statement opened with
// CURSOR_TYPE_SCROLLABLE, every fetch operation of IResultSet driven in
// a fixed script - next, prior, first, last, absolute (from either end,
// and 0), relative (either way, and 0), past both ends and back - each
// answer printed as "<op> -> <rc> [<id>]"; then the same operations on a
// cursor opened WITHOUT the flag (the engine's invalid-fetch-option
// vector). The scripted batches exercise the client's own re-positioning
// (it prefetches NEXT rows and sends a relative fetch when the direction
// turns). Every line is compared against the engine's.
//
//   scroll <connection-string>
#include <firebird/Interface.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
using namespace Firebird;

static IMaster* master = fb_get_master_interface();
static IUtil* utl = master->getUtilInterface();

static std::string err(const FbException& e) {
    char buf[1024];
    utl->formatStatus(buf, sizeof buf, e.getStatus());
    std::string s(buf);
    // one line, the stable part
    size_t nl = s.find('\n');
    if (nl != std::string::npos) s = s.substr(0, nl);
    return s;
}

struct Cur {
    IResultSet* rs; unsigned char* buf; unsigned idOff, nullOff;
    void show(const char* op, int rc) {
        if (rc == IStatus::RESULT_OK) printf("%s -> OK [%d]\n", op, *reinterpret_cast<int*>(buf + idOff));
        else if (rc == IStatus::RESULT_NO_DATA) printf("%s -> NO_DATA\n", op);
        else printf("%s -> rc %d\n", op, rc);
    }
};

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: scroll <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    ThrowStatusWrapper status(master->getStatus());
    IProvider* prov = master->getDispatcher();
    IAttachment* att = nullptr; ITransaction* tra = nullptr;
    try {
        IXpbBuilder* dpb = utl->getXpbBuilder(&status, IXpbBuilder::DPB, nullptr, 0);
        dpb->insertString(&status, isc_dpb_user_name, "SYSDBA");
        dpb->insertString(&status, isc_dpb_password, "masterkey");
        att = prov->attachDatabase(&status, argv[1], dpb->getBufferLength(&status), dpb->getBuffer(&status));
        tra = att->startTransaction(&status, 0, nullptr);
        const char* sql = "SELECT ID, V FROM S ORDER BY ID";
        auto open = [&](unsigned flags) {
            IStatement* st = att->prepare(&status, tra, 0, sql, 3, IStatement::PREPARE_PREFETCH_METADATA);
            IMessageMetadata* meta = st->getOutputMetadata(&status);
            Cur c;
            c.buf = new unsigned char[meta->getMessageLength(&status)];
            c.idOff = meta->getOffset(&status, 0);
            c.nullOff = meta->getNullOffset(&status, 0);
            c.rs = st->openCursor(&status, tra, nullptr, nullptr, meta, flags);
            return c;
        };
        // --- the scrollable cursor ---
        Cur c = open(IStatement::CURSOR_TYPE_SCROLLABLE);
        #define T(op, call) do { int rc; try { rc = (call); c.show(op, rc); } catch (const FbException& e) { printf("%s -> error %s\n", op, err(e).c_str()); } } while (0)
        T("next", c.rs->fetchNext(&status, c.buf));
        T("next", c.rs->fetchNext(&status, c.buf));
        T("next", c.rs->fetchNext(&status, c.buf));
        T("prior", c.rs->fetchPrior(&status, c.buf));
        T("prior", c.rs->fetchPrior(&status, c.buf));
        T("prior", c.rs->fetchPrior(&status, c.buf));
        T("prior(past start)", c.rs->fetchPrior(&status, c.buf));
        T("next(from start)", c.rs->fetchNext(&status, c.buf));
        T("first", c.rs->fetchFirst(&status, c.buf));
        T("last", c.rs->fetchLast(&status, c.buf));
        T("next(past end)", c.rs->fetchNext(&status, c.buf));
        T("next(still past)", c.rs->fetchNext(&status, c.buf));
        T("prior(from end)", c.rs->fetchPrior(&status, c.buf));
        T("absolute 3", c.rs->fetchAbsolute(&status, 3, c.buf));
        T("absolute -2", c.rs->fetchAbsolute(&status, -2, c.buf));
        T("absolute 0", c.rs->fetchAbsolute(&status, 0, c.buf));
        T("next(after abs 0)", c.rs->fetchNext(&status, c.buf));
        T("relative 2", c.rs->fetchRelative(&status, 2, c.buf));
        T("relative 0", c.rs->fetchRelative(&status, 0, c.buf));
        T("relative -1", c.rs->fetchRelative(&status, -1, c.buf));
        T("relative -10", c.rs->fetchRelative(&status, -10, c.buf));
        T("relative 0 (at start)", c.rs->fetchRelative(&status, 0, c.buf));
        T("relative -1 (at start)", c.rs->fetchRelative(&status, -1, c.buf));
        T("relative 4 (from start)", c.rs->fetchRelative(&status, 4, c.buf));
        T("absolute 100", c.rs->fetchAbsolute(&status, 100, c.buf));
        T("relative 1 (at end)", c.rs->fetchRelative(&status, 1, c.buf));
        T("relative -3 (from end)", c.rs->fetchRelative(&status, -3, c.buf));
        T("absolute -100", c.rs->fetchAbsolute(&status, -100, c.buf));
        T("last", c.rs->fetchLast(&status, c.buf));
        T("first", c.rs->fetchFirst(&status, c.buf));
        // a long forward run then a turn: the client's prefetch and its
        // relative re-positioning
        for (int i = 0; i < 5; i++) T("next", c.rs->fetchNext(&status, c.buf));
        T("prior(after run)", c.rs->fetchPrior(&status, c.buf));
        T("next", c.rs->fetchNext(&status, c.buf));
        T("isEof", c.rs->isEof(&status));
        T("isBof", c.rs->isBof(&status));
        c.rs->close(&status);
        // --- the plain cursor: every scroll op refuses ---
        Cur p = open(0);
        #define P(op, call) do { int rc; try { rc = (call); p.show(op, rc); } catch (const FbException& e) { printf("%s -> error %s\n", op, err(e).c_str()); } } while (0)
        P("plain next", p.rs->fetchNext(&status, p.buf));
        P("plain prior", p.rs->fetchPrior(&status, p.buf));
        P("plain first", p.rs->fetchFirst(&status, p.buf));
        P("plain last", p.rs->fetchLast(&status, p.buf));
        P("plain absolute 2", p.rs->fetchAbsolute(&status, 2, p.buf));
        P("plain relative 1", p.rs->fetchRelative(&status, 1, p.buf));
        P("plain next again", p.rs->fetchNext(&status, p.buf));
        p.rs->close(&status);
        tra->commit(&status); att->detach(&status);
        printf("done\n");
    } catch (const FbException& e) {
        printf("FAIL %s\n", err(e).c_str());
        return 1;
    }
    return 0;
}
