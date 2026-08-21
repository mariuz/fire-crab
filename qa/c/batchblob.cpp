// Blobs INSIDE a batch (IBatch addBlob / appendBlobData / setDefaultBpb /
// registerBlob / addBlobStream - op_batch_blob_stream, op_batch_set_bpb,
// op_batch_regblob): the blobs travel in the batch's blob stream ahead
// of the messages, each message's blob field names one by its BATCH id,
// and execute() turns them into the rows' blobs. Every line is compared
// against the engine's.
//
//   batchblob <connection-string>
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

static IBatch* make(IStatement* stmt, IMessageMetadata* meta, int policy, bool counts) {
    IXpbBuilder* pb = utl->getXpbBuilder(gstatus, IXpbBuilder::BATCH, nullptr, 0);
    if (counts) pb->insertInt(gstatus, IBatch::TAG_RECORD_COUNTS, 1);
    pb->insertInt(gstatus, IBatch::TAG_BLOB_POLICY, policy);
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
        try { cs->getStatus(gstatus, to, pos); printf("%s: error at %u: %s\n", tag, pos, err(to).c_str()); }
        catch (const FbException& e) { printf("%s: error at %u: %s\n", tag, pos, err(e.getStatus()).c_str()); }
        to->dispose();
    }
    cs->dispose();
}

// one blob's content (head), read through IBlob - the same way on both servers
static std::string blobHead(const ISC_QUAD* id, short isNull, long long* lenOut) {
    if (isNull) { *lenOut = -1; return "<null>"; }
    IBlob* bl = att->openBlob(gstatus, tra, const_cast<ISC_QUAD*>(id), 0, nullptr);
    std::string out; unsigned char buf[256]; unsigned got; long long total = 0;
    for (;;) {
        int rc = bl->getSegment(gstatus, sizeof buf, buf, &got);
        if (rc == IStatus::RESULT_NO_DATA) break;
        total += got;
        if (out.size() < 24) out.append(reinterpret_cast<char*>(buf), got);
        if (rc != IStatus::RESULT_OK && rc != IStatus::RESULT_SEGMENT) break;
    }
    bl->close(gstatus);
    *lenOut = total;
    if (out.size() > 24) out.resize(24);
    return out;
}

// every row: id, n, the two blobs' lengths and contents (head)
static void rows(const char* tag) {
    IStatement* st = att->prepare(gstatus, tra, 0, "SELECT ID, N, SEG, TXT FROM B ORDER BY ID", 3, IStatement::PREPARE_PREFETCH_METADATA);
    IMessageMetadata* m = st->getOutputMetadata(gstatus);
    unsigned char* buf = new unsigned char[m->getMessageLength(gstatus)];
    IResultSet* rs = st->openCursor(gstatus, tra, nullptr, nullptr, m, 0);
    printf("%s:\n", tag);
    while (rs->fetchNext(gstatus, buf) == IStatus::RESULT_OK) {
        int id = *reinterpret_cast<int*>(buf + m->getOffset(gstatus, 0));
        short nn = *reinterpret_cast<short*>(buf + m->getNullOffset(gstatus, 1));
        int n = *reinterpret_cast<int*>(buf + m->getOffset(gstatus, 1));
        ISC_QUAD q1, q2; memcpy(&q1, buf + m->getOffset(gstatus, 2), 8); memcpy(&q2, buf + m->getOffset(gstatus, 3), 8);
        short n1 = *reinterpret_cast<short*>(buf + m->getNullOffset(gstatus, 2));
        short n2 = *reinterpret_cast<short*>(buf + m->getNullOffset(gstatus, 3));
        long long l1, l2;
        std::string s1 = blobHead(&q1, n1, &l1), s2 = blobHead(&q2, n2, &l2);
        printf("  %d n=%s%d seg[%lld]='%s' txt[%lld]='%s'\n", id, nn ? "null " : "", nn ? 0 : n, l1, s1.c_str(), l2, s2.c_str());
    }
    rs->close(gstatus); m->release(); st->free(gstatus); delete[] buf;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: batchblob <conn>\n"); return 2; }
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

        IStatement* ins = att->prepare(&status, tra, 0, "INSERT INTO B (ID, N, SEG, TXT) VALUES (?, ?, ?, ?)", 3, IStatement::PREPARE_PREFETCH_METADATA);
        IMessageMetadata* meta = ins->getInputMetadata(&status);
        unsigned len = meta->getAlignedLength(&status);
        unsigned off[4], noff[4];
        for (int i = 0; i < 4; i++) { off[i] = meta->getOffset(&status, i); noff[i] = meta->getNullOffset(&status, i); }
        unsigned char* m = new unsigned char[len * 8];
        auto put = [&](unsigned char* p, int id, int n, const ISC_QUAD* seg, const ISC_QUAD* txt) {
            memset(p, 0, len);
            *reinterpret_cast<int*>(p + off[0]) = id;
            *reinterpret_cast<int*>(p + off[1]) = n;
            if (seg) memcpy(p + off[2], seg, 8); else *reinterpret_cast<short*>(p + noff[2]) = -1;
            if (txt) memcpy(p + off[3], txt, 8); else *reinterpret_cast<short*>(p + noff[3]) = -1;
        };
        const unsigned char segBpb[] = { isc_bpb_version1, isc_bpb_type, 1, isc_bpb_type_segmented };
        const unsigned char strBpb[] = { isc_bpb_version1, isc_bpb_type, 1, isc_bpb_type_stream };

        // 1. BLOB_ID_ENGINE: two blobs per row, appendBlobData, a NULL blob, the zero quad
        {
            IBatch* b = make(ins, meta, IBatch::BLOB_ID_ENGINE, true);
            ISC_QUAD s1, t1, s2, z; memset(&z, 0, sizeof z);
            b->addBlob(&status, 9, "seg-one-a", &s1, 0, nullptr);
            b->appendBlobData(&status, 6, "-more!");
            b->addBlob(&status, 8, "text-one", &t1, 0, nullptr);
            b->addBlob(&status, 7, "seg-two", &s2, 0, nullptr);
            put(m, 1, 10, &s1, &t1);
            put(m + len, 2, 20, &s2, nullptr);
            put(m + 2 * len, 3, 30, &z, &z);
            b->add(&status, 3, m);
            report("engine-ids", b->execute(&status, tra));
            b->release();
            rows("after engine-ids");
        }
        // 2. default bpb STREAM, then a per-blob SEGMENTED bpb, a big blob
        {
            IBatch* b = make(ins, meta, IBatch::BLOB_ID_ENGINE, false);
            b->setDefaultBpb(&status, sizeof strBpb, strBpb);
            ISC_QUAD s4, s5, t5;
            std::string big(5000, 'x'); big[0] = 'B'; big[4999] = 'E';
            b->addBlob(&status, big.size(), big.data(), &s4, 0, nullptr);
            b->addBlob(&status, 5, "segm-", &s5, sizeof segBpb, segBpb);
            b->appendBlobData(&status, 5, "ented");
            b->addBlob(&status, 11, "stream-text", &t5, 0, nullptr);
            put(m, 4, 40, &s4, nullptr);
            put(m + len, 5, 50, &s5, &t5);
            b->add(&status, 2, m);
            report("bpb", b->execute(&status, tra));
            b->release();
            rows("after bpb");
        }
        // 3. registerBlob: an existing blob (row 1's SEG) into a new row; an unknown id
        {
            // row 1's SEG id
            IStatement* q = att->prepare(&status, tra, 0, "SELECT SEG FROM B WHERE ID = 1", 3, IStatement::PREPARE_PREFETCH_METADATA);
            IMessageMetadata* qm = q->getOutputMetadata(&status);
            unsigned char* qb = new unsigned char[qm->getMessageLength(&status)];
            IResultSet* rs = q->openCursor(&status, tra, nullptr, nullptr, qm, 0);
            rs->fetchNext(&status, qb);
            ISC_QUAD existing; memcpy(&existing, qb + qm->getOffset(&status, 0), 8);
            rs->close(&status); qm->release(); q->free(&status); delete[] qb;

            IBatch* b = make(ins, meta, IBatch::BLOB_ID_ENGINE, true);
            ISC_QUAD r6, t6;
            b->registerBlob(&status, &existing, &r6);
            b->addBlob(&status, 10, "text-six!!", &t6, 0, nullptr);
            put(m, 6, 60, &r6, &t6);
            b->add(&status, 1, m);
            report("registered", b->execute(&status, tra));
            b->release();
            rows("after registered");

            IBatch* b2 = make(ins, meta, IBatch::BLOB_ID_ENGINE, true);
            ISC_QUAD bogus = { 77, 99 };
            put(m, 7, 70, &bogus, nullptr);
            b2->add(&status, 1, m);
            try { report("unknown-id", b2->execute(&status, tra)); }
            catch (const FbException& e) { printf("unknown-id: error %s\n", err(e.getStatus()).c_str()); }
            b2->release();
            rows("after unknown-id");
        }
        // 4. BLOB_ID_USER: the client's own ids; one id used by TWO messages (second is unknown)
        {
            IBatch* b = make(ins, meta, IBatch::BLOB_ID_USER, true);
            ISC_QUAD u1 = { 1, 1 }, u2 = { 1, 2 };
            b->addBlob(&status, 9, "user-one!", &u1, 0, nullptr);
            b->addBlob(&status, 9, "user-two!", &u2, 0, nullptr);
            put(m, 8, 80, &u1, &u2);
            put(m + len, 9, 90, &u1, nullptr);
            b->add(&status, 2, m);
            try { report("user-ids", b->execute(&status, tra)); }
            catch (const FbException& e) { printf("user-ids: error %s\n", err(e.getStatus()).c_str()); }
            b->release();
            rows("after user-ids");
        }
        // 5. BLOB_STREAM: the stream built by hand (header: quad, total, bpb length; segmented data)
        {
            IBatch* b = make(ins, meta, IBatch::BLOB_STREAM, true);
            unsigned align = b->getBlobAlignment(&status);
            printf("blob alignment %u\n", align);
            std::string stream;
            auto put32 = [&](unsigned v) { stream.append(reinterpret_cast<const char*>(&v), 4); };
            auto put16 = [&](unsigned short v) { stream.append(reinterpret_cast<const char*>(&v), 2); };
            auto pad = [&](unsigned a) { while (stream.size() % a) stream.push_back(0); };
            ISC_QUAD h1 = { 5, 1 }, h2 = { 5, 2 };
            // blob 1: segmented (default), two segments
            stream.append(reinterpret_cast<const char*>(&h1), 8); put32(2 + 6 + 2 + 5); put32(0);
            put16(6); stream.append("hand-1"); pad(2); put16(5); stream.append("seg-b");
            pad(align);
            // blob 2: a stream bpb, one run
            stream.append(reinterpret_cast<const char*>(&h2), 8); put32(sizeof strBpb + 12); put32(sizeof strBpb);
            stream.append(reinterpret_cast<const char*>(strBpb), sizeof strBpb); stream.append("hand-stream2");
            pad(align);
            b->addBlobStream(&status, stream.size(), stream.data());
            put(m, 10, 100, &h1, &h2);
            b->add(&status, 1, m);
            report("hand-stream", b->execute(&status, tra));
            b->release();
            rows("after hand-stream");
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
