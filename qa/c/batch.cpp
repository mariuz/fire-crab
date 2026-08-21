// The batch API differential (IBatch, DsqlBatch.cpp): one prepared
// INSERT and one UPDATE fed by IBatch::add and run by execute(), the
// completion state read back - getSize, a state per message (the update
// count under TAG_RECORD_COUNTS, SUCCESS_NO_INFO without, EXECUTE_FAILED
// for a failure), every failure's position and its vector - under the
// default knobs (stop at the first failure), under TAG_MULTIERROR, and
// with TAG_RECORD_COUNTS; then what the table holds. Every line is
// compared against the engine's.
//
//   batch <connection-string>
#include <firebird/Interface.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
using namespace Firebird;

static IMaster* master = fb_get_master_interface();
static IUtil* utl = master->getUtilInterface();
static IAttachment* att = nullptr;
static ITransaction* tra = nullptr;
static ThrowStatusWrapper* gstatus;

static std::string err(IStatus* st) {
    char buf[1024];
    utl->formatStatus(buf, sizeof buf, st);
    std::string s(buf);
    size_t nl = s.find('\n');
    if (nl != std::string::npos) s = s.substr(0, nl);
    return s;
}

// the batch's knobs
static IBatch* make(IStatement* stmt, IMessageMetadata* meta, bool multi, bool counts, int detailed) {
    IXpbBuilder* pb = utl->getXpbBuilder(gstatus, IXpbBuilder::BATCH, nullptr, 0);
    if (multi) pb->insertInt(gstatus, IBatch::TAG_MULTIERROR, 1);
    if (counts) pb->insertInt(gstatus, IBatch::TAG_RECORD_COUNTS, 1);
    if (detailed >= 0) pb->insertInt(gstatus, IBatch::TAG_DETAILED_ERRORS, detailed);
    IBatch* b = stmt->createBatch(gstatus, meta, pb->getBufferLength(gstatus), pb->getBuffer(gstatus));
    pb->dispose();
    return b;
}

static void report(const char* tag, IBatchCompletionState* cs) {
    unsigned n = cs->getSize(gstatus);
    printf("%s: size %u states", tag, n);
    for (unsigned i = 0; i < n; i++) {
        int st = cs->getState(gstatus, i);
        if (st == IBatchCompletionState::EXECUTE_FAILED) printf(" FAILED");
        else if (st == IBatchCompletionState::SUCCESS_NO_INFO) printf(" OK");
        else printf(" %d", st);
    }
    printf("\n");
    for (unsigned pos = 0; (pos = cs->findError(gstatus, pos)) != IBatchCompletionState::NO_MORE_ERRORS; ++pos) {
        IStatus* to = master->getStatus();
        try {
            cs->getStatus(gstatus, to, pos);
            printf("%s: error at %u: %s\n", tag, pos, (to->getState() & IStatus::STATE_ERRORS) ? err(to).c_str() : "(no vector)");
        } catch (const FbException& e) {
            // past TAG_DETAILED_ERRORS the position is known, the vector is not
            printf("%s: error at %u: %s\n", tag, pos, err(e.getStatus()).c_str());
        }
        to->dispose();
    }
    cs->dispose();
}

static void count(const char* tag) {
    IStatement* st = att->prepare(gstatus, tra, 0, "SELECT COUNT(*), COALESCE(SUM(ID), 0), COALESCE(MAX(V), '-') FROM B", 3, IStatement::PREPARE_PREFETCH_METADATA);
    IMessageMetadata* m = st->getOutputMetadata(gstatus);
    unsigned char* buf = new unsigned char[m->getMessageLength(gstatus)];
    IResultSet* rs = st->openCursor(gstatus, tra, nullptr, nullptr, m, 0);
    rs->fetchNext(gstatus, buf);
    long long c = *reinterpret_cast<long long*>(buf + m->getOffset(gstatus, 0));
    long long sum = *reinterpret_cast<long long*>(buf + m->getOffset(gstatus, 1));
    unsigned char* v = buf + m->getOffset(gstatus, 2);
    unsigned short vl = *reinterpret_cast<unsigned short*>(v);
    printf("%s: count %lld sum %lld max '%.*s'\n", tag, c, sum, vl, v + 2);
    rs->close(gstatus); m->release(); st->free(gstatus); delete[] buf;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: batch <conn>\n"); return 2; }
    setvbuf(stdout, NULL, _IOLBF, 0);
    ThrowStatusWrapper status(master->getStatus());
    gstatus = &status;
    IProvider* prov = master->getDispatcher();
    try {
        IXpbBuilder* dpb = utl->getXpbBuilder(&status, IXpbBuilder::DPB, nullptr, 0);
        dpb->insertString(&status, isc_dpb_user_name, "SYSDBA");
        dpb->insertString(&status, isc_dpb_password, "masterkey");
        att = prov->attachDatabase(&status, argv[1], dpb->getBufferLength(&status), dpb->getBuffer(&status));
        tra = att->startTransaction(&status, 0, nullptr);

        IStatement* ins = att->prepare(&status, tra, 0, "INSERT INTO B (ID, V) VALUES (?, ?)", 3, IStatement::PREPARE_PREFETCH_METADATA);
        IMessageMetadata* meta = ins->getInputMetadata(&status);
        // IBatch::add reads messages at the ALIGNED stride
        unsigned len = meta->getAlignedLength(&status);
        unsigned idOff = meta->getOffset(&status, 0), idNull = meta->getNullOffset(&status, 0);
        unsigned vOff = meta->getOffset(&status, 1), vNull = meta->getNullOffset(&status, 1);
        auto put = [&](unsigned char* m, int id, const char* v) {
            memset(m, 0, len);
            *reinterpret_cast<int*>(m + idOff) = id; *reinterpret_cast<short*>(m + idNull) = 0;
            if (v) { unsigned short l = strlen(v); *reinterpret_cast<unsigned short*>(m + vOff) = l; memcpy(m + vOff + 2, v, l); *reinterpret_cast<short*>(m + vNull) = 0; }
            else *reinterpret_cast<short*>(m + vNull) = -1;
        };
        unsigned char* m = new unsigned char[len * 8];

        // 1. default knobs: five rows, the third a PRIMARY KEY duplicate
        {
            IBatch* b = make(ins, meta, false, false, -1);
            put(m + 0 * len, 1, "one"); put(m + 1 * len, 2, "two"); put(m + 2 * len, 1, "dup");
            put(m + 3 * len, 4, "four"); put(m + 4 * len, 5, NULL);
            b->add(&status, 5, m);
            report("default", b->execute(&status, tra));
            b->release();
            count("after default");
        }
        // 2. MULTIERROR + RECORD_COUNTS: the run goes on past the failures
        {
            IBatch* b = make(ins, meta, true, true, -1);
            put(m + 0 * len, 1, "again"); put(m + 1 * len, 3, "three"); put(m + 2 * len, 2, "dup2");
            put(m + 3 * len, 6, "six"); put(m + 4 * len, 6, "dup6");
            b->add(&status, 3, m);
            b->add(&status, 2, m + 3 * len);
            report("multi+counts", b->execute(&status, tra));
            b->release();
            count("after multi");
        }
        // 3. RECORD_COUNTS alone, an UPDATE touching several rows per message
        {
            IStatement* upd = att->prepare(&status, tra, 0, "UPDATE B SET V = ? WHERE ID <= ?", 3, IStatement::PREPARE_PREFETCH_METADATA);
            IMessageMetadata* um = upd->getInputMetadata(&status);
            unsigned ul = um->getAlignedLength(&status);
            unsigned char* u = new unsigned char[ul * 3];
            auto putu = [&](unsigned char* p, const char* v, int id) {
                memset(p, 0, ul);
                unsigned short l = strlen(v);
                *reinterpret_cast<unsigned short*>(p + um->getOffset(&status, 0)) = l; memcpy(p + um->getOffset(&status, 0) + 2, v, l);
                *reinterpret_cast<int*>(p + um->getOffset(&status, 1)) = id;
            };
            putu(u, "low", 2); putu(u + ul, "mid", 4); putu(u + 2 * ul, "none", 0);
            IBatch* b = make(upd, um, false, true, -1);
            b->add(&status, 3, u);
            report("update+counts", b->execute(&status, tra));
            b->release();
            count("after update");
            um->release(); upd->free(&status); delete[] u;
        }
        // 4. MULTIERROR with DETAILED_ERRORS 1: the second failure has no vector
        {
            IBatch* b = make(ins, meta, true, false, 1);
            put(m + 0 * len, 1, "x"); put(m + 1 * len, 2, "y"); put(m + 2 * len, 7, "seven");
            b->add(&status, 3, m);
            report("detailed=1", b->execute(&status, tra));
            b->release();
            count("after detailed");
        }
        // 5. an empty batch, and a second batch on the same statement
        {
            IBatch* b = make(ins, meta, false, false, -1);
            report("empty", b->execute(&status, tra));
            put(m, 8, "eight");
            b->add(&status, 1, m);
            report("reused", b->execute(&status, tra));
            b->release();
            count("after reuse");
        }
        // 6. a second createBatch while one is open
        {
            IBatch* b = make(ins, meta, false, false, -1);
            try { IBatch* b2 = make(ins, meta, false, false, -1); b2->release(); printf("second batch: opened\n"); }
            catch (const FbException& e) { printf("second batch: %s\n", err(e.getStatus()).c_str()); }
            b->release();
        }
        delete[] m; meta->release(); ins->free(&status);
        tra->commit(&status); att->detach(&status);
        printf("done\n");
    } catch (const FbException& e) {
        printf("FAIL %s\n", err(e.getStatus()).c_str());
        return 1;
    }
    return 0;
}
