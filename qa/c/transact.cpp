// op_ping and op_transact: IAttachment::ping, then transactRequest - a
// BLR request compiled, started with its input message and run to
// completion in one round trip, the output message in the response.
// The BLR below: message 0 (one long, the input - the engine fills it in
// BEFORE the start; a blr_receive would stall), message 1 (two longs),
// receive 0, for over RDB$DATABASE send 1 <RDB$RELATION_ID, the input
// echoed>. Then a request whose BLR is broken. Every line is compared
// against the engine's.
//
//   transact <connection-string>
#include <firebird/Interface.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
using namespace Firebird;

static IMaster* master = fb_get_master_interface();
static IUtil* utl = master->getUtilInterface();
static std::string err(IStatus* st) {
    char buf[1024]; utl->formatStatus(buf, sizeof buf, st);
    std::string s(buf); size_t nl = s.find('\n'); if (nl != std::string::npos) s = s.substr(0, nl); return s;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: transact <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    ThrowStatusWrapper status(master->getStatus());
    IProvider* prov = master->getDispatcher();
    try {
        IXpbBuilder* dpb = utl->getXpbBuilder(&status, IXpbBuilder::DPB, nullptr, 0);
        dpb->insertString(&status, isc_dpb_user_name, "SYSDBA");
        dpb->insertString(&status, isc_dpb_password, "masterkey");
        IAttachment* att = prov->attachDatabase(&status, argv[1], dpb->getBufferLength(&status), dpb->getBuffer(&status));
        att->ping(&status); printf("ping: ok\n");
        ITransaction* tra = att->startTransaction(&status, 0, nullptr);
        const unsigned char blr[] = {
            5, 2,
            4, 0, 1, 0, 8, 0,
            4, 1, 2, 0, 8, 0, 8, 0,
              7,
                67, 1, 74, 12, 'R','D','B','$','D','A','T','A','B','A','S','E', 0, 255,
                14, 1, 2,
                  1, 23, 0, 15, 'R','D','B','$','R','E','L','A','T','I','O','N','_','I','D', 25, 1, 0, 0,
                  1, 25, 0, 0, 0, 25, 1, 1, 0,
                255,
            255, 76 };
        int in = 42; int out[2] = { -1, -1 };
        att->transactRequest(&status, tra, sizeof blr, blr, sizeof in, reinterpret_cast<unsigned char*>(&in), sizeof out, reinterpret_cast<unsigned char*>(out));
        printf("transact: relation id %d, echo %d\n", out[0], out[1]);
        in = 7; out[0] = out[1] = -1;
        att->transactRequest(&status, tra, sizeof blr, blr, sizeof in, reinterpret_cast<unsigned char*>(&in), sizeof out, reinterpret_cast<unsigned char*>(out));
        printf("transact again: relation id %d, echo %d\n", out[0], out[1]);
        att->ping(&status); printf("ping again: ok\n");
        const unsigned char bad[] = { 5, 2, 4, 1, 1, 0, 8, 0, 99, 255, 76 };
        try { att->transactRequest(&status, tra, sizeof bad, bad, 0, nullptr, sizeof out, reinterpret_cast<unsigned char*>(out)); printf("bad blr: accepted?!\n"); }
        catch (const FbException& e) { std::string m = err(e.getStatus()); printf("bad blr: %s\n", m.substr(0, 12).c_str()); }
        tra->commit(&status); att->detach(&status);
        printf("done\n");
    } catch (const FbException& e) { printf("FAIL %s\n", err(e.getStatus()).c_str()); return 1; }
    return 0;
}
