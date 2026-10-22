using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using static MAVLink;

/// Файлові операції через MAVLink: MAVFTP (скрипти на SD-картці) та завантаження Dataflash-логів (LOG_REQUEST_*).
/// Усі структури розбираються з сирих байтів (рефлексія на packed-структурах небезпечна на Apple Silicon).
class FtpException : Exception
{
    public int Code;
    public FtpException(string msg, int code = 0) : base(msg) { Code = code; }
}

class DfEntry { public int id; public uint size; public uint timeUtc; }

class DfStatus
{
    public string state { get; set; } = "idle";   // idle | running | done | error | cancelled
    public int id { get; set; }
    public long size { get; set; }
    public long received { get; set; }
    public string path { get; set; }
    public string error { get; set; }
    public double bps { get; set; }
}

partial class Link
{
    // ---------- Перехоплення вхідних пакетів ----------
    readonly BlockingCollection<byte[]> ftpRx = new BlockingCollection<byte[]>(new ConcurrentQueue<byte[]>(), 8192);
    readonly BlockingCollection<(uint ofs, byte[] data)> dfRx = new BlockingCollection<(uint, byte[])>(new ConcurrentQueue<(uint, byte[])>(), 4096);
    readonly object dfLk = new object();
    readonly Dictionary<int, DfEntry> dfEntries = new Dictionary<int, DfEntry>();
    int dfNum; DateTime dfLastEntry = DateTime.MinValue;
    volatile bool dfDownloading;

    static byte[] Pad(byte[] p, int n) { if (p.Length >= n) return p; var r = new byte[n]; Array.Copy(p, r, p.Length); return r; }

    void Intercept(MAVLinkMessage m)
    {
        MissionIntercept(m);
        HardwareIntercept(m);
        switch ((MAVLINK_MSG_ID)m.msgid)
        {
            case MAVLINK_MSG_ID.FILE_TRANSFER_PROTOCOL:
                {
                    var p = Pad(Payload(m), 254);
                    var r = new byte[251]; Array.Copy(p, 3, r, 0, 251);
                    if (!ftpRx.TryAdd(r)) { }
                    break;
                }
            case MAVLINK_MSG_ID.LOG_ENTRY:
                {
                    var p = Pad(Payload(m), 14);
                    var e = new DfEntry { timeUtc = BitConverter.ToUInt32(p, 0), size = BitConverter.ToUInt32(p, 4), id = BitConverter.ToUInt16(p, 8) };
                    int num = BitConverter.ToUInt16(p, 10);
                    lock (dfLk) { dfNum = num; dfLastEntry = DateTime.UtcNow; if (num > 0 && e.id > 0) dfEntries[e.id] = e; }
                    break;
                }
            case MAVLINK_MSG_ID.LOG_DATA:
                {
                    if (!dfDownloading) break;
                    var p = Pad(Payload(m), 97);
                    uint ofs = BitConverter.ToUInt32(p, 0);
                    int cnt = Math.Min((int)p[6], 90);
                    var d = new byte[cnt]; Array.Copy(p, 7, d, 0, cnt);
                    dfRx.TryAdd((ofs, d));
                    break;
                }
        }
    }

    // ================= MAVFTP =================
    const int FtpHdr = 12, FtpMax = 239;
    readonly SemaphoreSlim ftpLock = new SemaphoreSlim(1, 1);
    ushort ftpSeq;

    class FtpReply { public byte op, reqOp, session; public int size; public uint offset; public byte[] data; public ushort seq; }

    void FtpSend(ushort seq, byte op, byte session, uint offset, byte[] data, int reqSize = -1)
    {
        var pl = new byte[251];
        pl[0] = (byte)(seq & 0xff); pl[1] = (byte)(seq >> 8);
        pl[2] = session; pl[3] = op; pl[4] = (byte)(reqSize >= 0 ? reqSize : (data?.Length ?? 0));
        Array.Copy(BitConverter.GetBytes(offset), 0, pl, 8, 4);
        if (data != null) Array.Copy(data, 0, pl, FtpHdr, data.Length);
        Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.FILE_TRANSFER_PROTOCOL,
            new mavlink_file_transfer_protocol_t(0, targetSys, targetComp, pl), false, 255, 190, 0));
    }

    /// Один запит-відповідь з повторами. Кидає FtpException при Nak (крім EOF, який повертається як reply з op=129).
    FtpReply FtpCall(byte op, byte session, uint offset, byte[] data, int timeoutMs = 1200, int retries = 5, int reqSize = -1)
    {
        for (int attempt = 0; attempt < retries; attempt++)
        {
            while (ftpRx.TryTake(out _)) { }
            var seq = unchecked((ushort)(ftpSeq++));
            FtpSend(seq, op, session, offset, data, reqSize);
            var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
            while (true)
            {
                var left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
                if (left <= 0) break;
                if (!ftpRx.TryTake(out var r, left)) break;
                var rseq = (ushort)(r[0] | r[1] << 8);
                var rep = new FtpReply { seq = rseq, session = r[2], op = r[3], size = r[4], reqOp = r[5], offset = BitConverter.ToUInt32(r, 8) };
                if (rep.reqOp != op || rseq != unchecked((ushort)(seq + 1))) continue;
                rep.data = new byte[Math.Min(rep.size, FtpMax)]; Array.Copy(r, FtpHdr, rep.data, 0, rep.data.Length);
                if (rep.op == 129)
                {
                    int code = rep.data.Length > 0 ? rep.data[0] : 1;
                    if (code == 6) return rep;      // EOF
                    int errno = rep.data.Length > 1 ? rep.data[1] : 0;
                    if (code == 2 && (errno == 16 || errno == 19 || errno == 5)) throw new FtpException("SD-картка недоступна: її немає, вона не вставлена, не відформатована або зайнята (errno " + errno + ")", code);
                    if (code == 2 && errno == 2) throw new FtpException("Папку чи файл не знайдено: на польотнику, найімовірніше, немає SD-картки (або вона не відформатована, або папка не створена)", 10);
                    if (code == 2 && errno != 0) throw new FtpException("Помилка файлової системи польотника (errno " + errno + "): перевірте SD-картку", code);
                    throw new FtpException(code switch { 10 => "Файл не знайдено", 8 => "Файл уже існує", 9 => "Файл захищений", 5 => "Немає вільних сесій FTP", _ => "Помилка FTP (код " + code + ")" }, code);
                }
                return rep;
            }
        }
        throw new FtpException("Польотник не відповідає на MAVFTP. Потрібна SD-картка та підтримка FTP.", -1);
    }

    public class FtpItem { public string name { get; set; } public bool dir { get; set; } public long size { get; set; } }

    public List<FtpItem> FtpList(string path)
    {
        ftpLock.Wait();
        try
        {
            try { FtpCall(2, 0, 0, null, 800, 2); } catch (FtpException) { }
            var items = new List<FtpItem>();
            uint idx = 0;
            while (true)
            {
                var rep = FtpCall(3, 0, idx, Encoding.UTF8.GetBytes(path));
                if (rep.op == 129 || rep.data.Length == 0) break;
                int n = 0, start = 0;
                for (int i = 0; i < rep.data.Length; i++)
                {
                    if (rep.data[i] != 0) continue;
                    var s = Encoding.UTF8.GetString(rep.data, start, i - start); start = i + 1; n++;
                    if (s.Length == 0) continue;
                    if (s[0] == 'D') items.Add(new FtpItem { name = s.Substring(1), dir = true });
                    else if (s[0] == 'F')
                    {
                        var parts = s.Substring(1).Split('\t');
                        items.Add(new FtpItem { name = parts[0], size = parts.Length > 1 && long.TryParse(parts[1], out var sz) ? sz : 0 });
                    }
                }
                if (n == 0) break;
                idx += (uint)n;
                if (idx > 5000) break;
            }
            return items;
        }
        finally { ftpLock.Release(); }
    }

    public byte[] FtpRead(string path)
    {
        ftpLock.Wait();
        try
        {
            try { FtpCall(2, 0, 0, null, 800, 2); } catch (FtpException) { }
            var open = FtpCall(4, 0, 0, Encoding.UTF8.GetBytes(path));
            byte session = open.session;
            long size = open.data.Length >= 4 ? BitConverter.ToUInt32(open.data, 0) : 0;
            if (size == 0) { try { FtpCall(1, session, 0, null, 800, 2); } catch (FtpException) { } return new byte[0]; }
            var ms = new MemoryStream();
            try
            {
                while (ms.Length < size)
                {
                    var rep = FtpCall(5, session, (uint)ms.Length, null, 1200, 5, FtpMax);
                    if (rep.op == 129 || rep.data.Length == 0) break;
                    ms.Write(rep.data, 0, rep.data.Length);
                }
            }
            finally { try { FtpCall(1, session, 0, null, 800, 2); } catch (FtpException) { } }
            return ms.ToArray();
        }
        finally { ftpLock.Release(); }
    }

    /// Швидке завантаження файлу пакетним читанням MAVFTP (BurstReadFile) у потік. Кидає FtpException, якщо файлу немає.
    public void FtpDownload(string path, Stream dest, Action<long, long> progress, CancellationToken ct)
    {
        ftpLock.Wait();
        try
        {
            try { FtpCall(2, 0, 0, null, 800, 2); } catch (FtpException) { }
            var open = FtpCall(4, 0, 0, Encoding.UTF8.GetBytes(path));
            byte session = open.session;
            long size = open.data.Length >= 4 ? BitConverter.ToUInt32(open.data, 0) : 0;
            try
            {
                long next = 0; int stalls = 0;
                while (next < size)
                {
                    ct.ThrowIfCancellationRequested();
                    while (ftpRx.TryTake(out _)) { }
                    var seq = unchecked((ushort)(ftpSeq++));
                    FtpSend(seq, 15, session, (uint)next, null, FtpMax);
                    bool got = false, burstDone = false;
                    while (!burstDone)
                    {
                        if (ct.IsCancellationRequested) throw new OperationCanceledException();
                        if (!ftpRx.TryTake(out var r, 700)) break;          // тиша: повторюємо запит з поточного місця
                        if (r[3] != 129 && r[3] != 128) continue;
                        if (r[5] != 15) continue;
                        if (r[3] == 129)
                        {
                            int code = r[12];
                            if (code == 6) { next = size; break; }          // EOF
                            throw new FtpException("Помилка FTP під час читання файлу (код " + code + ")", code);
                        }
                        uint off = BitConverter.ToUInt32(r, 8); int n = Math.Min((int)r[4], FtpMax);
                        if (off == next && n > 0)
                        {
                            dest.Write(r, FtpHdr, n); next += n; got = true;
                            progress?.Invoke(next, size);
                            if (next >= size) break;
                        }
                        if (r[6] != 0) burstDone = true;                    // кінець пакета-пачки
                    }
                    if (got) stalls = 0; else if (++stalls > 8) throw new FtpException("Польотник перестав віддавати файл", -1);
                }
            }
            finally { try { FtpCall(1, session, 0, null, 800, 2); } catch (FtpException) { } }
        }
        finally { ftpLock.Release(); }
    }

    /// Швидке читання файлу (пакетне, MAVFTP BurstReadFile) із запасним повільним шляхом.
    public byte[] FtpReadFast(string path)
    {
        try { var ms = new MemoryStream(); FtpDownload(path, ms, null, CancellationToken.None); return ms.ToArray(); }
        catch (FtpException e) when (e.Code == -1) { return FtpRead(path); }
    }

    // ---------- Завантаження файлу з польотника на диск у фоні (з прогресом) ----------
    public class FtpGetStatus
    {
        public string state { get; set; } = "idle";      // idle | running | done | error | cancelled
        public string path { get; set; } = ""; public string dest { get; set; } = "";
        public long size { get; set; } public long received { get; set; } public double bps { get; set; }
        public string error { get; set; }
    }
    readonly FtpGetStatus ftpGet = new FtpGetStatus();
    CancellationTokenSource ftpGetCts;
    public object FtpGetState() { lock (ftpGet) return new FtpGetStatus { state = ftpGet.state, path = ftpGet.path, dest = ftpGet.dest, size = ftpGet.size, received = ftpGet.received, bps = ftpGet.bps, error = ftpGet.error }; }
    public void FtpGetCancel() { try { ftpGetCts?.Cancel(); } catch { } }
    public bool FtpGetStart(string path, string dest)
    {
        lock (ftpGet) { if (ftpGet.state == "running") return false; ftpGet.state = "running"; ftpGet.path = path; ftpGet.dest = dest; ftpGet.size = 0; ftpGet.received = 0; ftpGet.bps = 0; ftpGet.error = null; }
        ftpGetCts = new CancellationTokenSource(); var ct = ftpGetCts.Token;
        System.Threading.Tasks.Task.Run(() =>
        {
            bool cancelled = false; string err = null; var t0 = DateTime.UtcNow;
            try
            {
                using var fs = new FileStream(dest, FileMode.Create, FileAccess.Write);
                FtpDownload(path, fs, (rec, tot) => { lock (ftpGet) { ftpGet.received = rec; ftpGet.size = tot; var dt = (DateTime.UtcNow - t0).TotalSeconds; if (dt > 0.5) ftpGet.bps = rec / dt; } }, ct);
            }
            catch (OperationCanceledException) { cancelled = true; }
            catch (Exception e) { err = e.Message; }
            lock (ftpGet)
            {
                if (cancelled) { ftpGet.state = "cancelled"; try { File.Delete(dest); } catch { } }
                else if (err != null) { ftpGet.state = "error"; ftpGet.error = err; try { File.Delete(dest); } catch { } }
                else ftpGet.state = "done";
            }
        });
        return true;
    }

    public void FtpWrite(string path, byte[] content)
    {
        ftpLock.Wait();
        try
        {
            try { FtpCall(2, 0, 0, null, 800, 2); } catch (FtpException) { }
            var open = FtpCall(6, 0, 0, Encoding.UTF8.GetBytes(path));
            byte session = open.session;
            try
            {
                int ofs = 0;
                while (ofs < content.Length)
                {
                    int n = Math.Min(FtpMax, content.Length - ofs);
                    var chunk = new byte[n]; Array.Copy(content, ofs, chunk, 0, n);
                    FtpCall(7, session, (uint)ofs, chunk);
                    ofs += n;
                }
            }
            finally { try { FtpCall(1, session, 0, null, 800, 2); } catch (FtpException) { } }
        }
        finally { ftpLock.Release(); }
    }

    void FtpSimple(byte op, byte[] data)
    {
        ftpLock.Wait();
        try { try { FtpCall(2, 0, 0, null, 800, 2); } catch (FtpException) { } FtpCall(op, 0, 0, data); }
        finally { ftpLock.Release(); }
    }
    public void FtpRemove(string path) => FtpSimple(8, Encoding.UTF8.GetBytes(path));
    public void FtpMkdir(string path) => FtpSimple(9, Encoding.UTF8.GetBytes(path));
    public void FtpRename(string from, string to) => FtpSimple(13, Encoding.UTF8.GetBytes(from).Concat(new byte[] { 0 }).Concat(Encoding.UTF8.GetBytes(to)).Concat(new byte[] { 0 }).ToArray());

    // ================= Dataflash-логи =================
    public List<DfEntry> DfList()
    {
        lock (dfLk) { dfEntries.Clear(); dfNum = -1; dfLastEntry = DateTime.MinValue; }
        for (int attempt = 0; attempt < 3; attempt++)
        {
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.LOG_REQUEST_LIST, new mavlink_log_request_list_t(0, 0xFFFF, targetSys, targetComp), false, 255, 190, 0));
            var started = DateTime.UtcNow;
            while ((DateTime.UtcNow - started).TotalSeconds < 6)
            {
                Thread.Sleep(80);
                lock (dfLk)
                {
                    if (dfNum == 0) return new List<DfEntry>();
                    if (dfNum > 0 && dfEntries.Count >= dfNum) goto done;
                    if (dfLastEntry != DateTime.MinValue && (DateTime.UtcNow - dfLastEntry).TotalSeconds > 1.5) break;   // тиша: повторимо запит
                }
            }
            lock (dfLk) { if (dfEntries.Count > 0 && attempt == 2) break; }
        }
        done:
        lock (dfLk) return dfEntries.Values.OrderBy(e => e.id).ToList();
    }

    DfStatus dfStatus = new DfStatus();
    CancellationTokenSource dfCts;
    public DfStatus DfState { get { lock (dfLk) return new DfStatus { state = dfStatus.state, id = dfStatus.id, size = dfStatus.size, received = dfStatus.received, path = dfStatus.path, error = dfStatus.error, bps = dfStatus.bps }; } }

    public static string DfDir
    {
        get
        {
            var d = !string.IsNullOrEmpty(LogRoot) ? LogRoot : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ArduTune", "DFLogs");
            Directory.CreateDirectory(d); return d;
        }
    }

    public bool DfDownload(int id)
    {
        DfEntry e;
        lock (dfLk)
        {
            if (dfDownloading) return false;
            if (!dfEntries.TryGetValue(id, out e)) return false;
            dfStatus = new DfStatus { state = "running", id = id, size = e.size };
        }
        var when = e.timeUtc > 0 ? DateTimeOffset.FromUnixTimeSeconds(e.timeUtc).LocalDateTime : DateTime.Now;
        var path = Path.Combine(DfDir, $"{vehicleTag()}_{id:000}_{when:yyyyMMdd-HHmmss}.bin");
        lock (dfLk) dfStatus.path = path;
        dfCts = new CancellationTokenSource();
        var ct = dfCts.Token;
        dfDownloading = true;
        while (dfRx.TryTake(out _)) { }
        Task.Run(() => DfDownloadLoop(e, path, ct));
        return true;
    }

    string vehicleTag() { lock (lk) return (T.vehicle ?? "Log").Replace("MAV_TYPE_", "").Replace(" ", ""); }

    void DfDownloadLoop(DfEntry e, string path, CancellationToken ct)
    {
        string err = null; bool cancelled = false;
        try
        {
            using var fs = new FileStream(path, FileMode.Create, FileAccess.Write);
            // швидкий шлях: MAVFTP із SD-картки (/APM/LOGS/NNNNNNNN.BIN); якщо недоступний, нижче старий LOG_REQUEST_DATA
            {
                var t1 = DateTime.UtcNow; bool ftpOk = false;
                try
                {
                    FtpDownload($"/APM/LOGS/{e.id:00000000}.BIN", fs, (rec, tot) =>
                    {
                        lock (dfLk) { dfStatus.received = rec; var dt = (DateTime.UtcNow - t1).TotalSeconds; if (dt > 0.5) dfStatus.bps = rec / dt; }
                    }, ct);
                    ftpOk = true;
                }
                catch (OperationCanceledException) { cancelled = true; }
                catch (FtpException) { fs.SetLength(0); fs.Position = 0; lock (dfLk) dfStatus.received = 0; }
                if (cancelled || ftpOk) return;
            }
            uint next = 0, total = e.size;
            var lastReq = DateTime.MinValue; var lastRx = DateTime.UtcNow; int stalls = 0;
            var t0 = DateTime.UtcNow;
            void Request() { lastReq = DateTime.UtcNow; Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.LOG_REQUEST_DATA, new mavlink_log_request_data_t(next, total - next, (ushort)e.id, targetSys, targetComp), false, 255, 190, 0)); }
            Request();
            while (next < total)
            {
                if (ct.IsCancellationRequested) { cancelled = true; break; }
                if (dfRx.TryTake(out var pkt, 400))
                {
                    lastRx = DateTime.UtcNow; stalls = 0;
                    if (pkt.ofs == next)
                    {
                        int n = (int)Math.Min((uint)pkt.data.Length, total - next);
                        fs.Write(pkt.data, 0, n); next += (uint)n;
                        lock (dfLk) { dfStatus.received = next; var dt = (DateTime.UtcNow - t0).TotalSeconds; if (dt > 0.5) dfStatus.bps = next / dt; }
                    }
                    else if (pkt.ofs > next && (DateTime.UtcNow - lastReq).TotalMilliseconds > 400) Request();   // пропуск: перезапит з потрібного місця
                }
                else if ((DateTime.UtcNow - lastRx).TotalMilliseconds > 1500)
                {
                    if (++stalls > 8) throw new Exception("Польотник перестав віддавати дані логу");
                    lastRx = DateTime.UtcNow; Request();
                }
            }
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.LOG_REQUEST_END, new mavlink_log_request_end_t(targetSys, targetComp), false, 255, 190, 0));
        }
        catch (Exception ex) { err = ex.Message; }
        finally
        {
            dfDownloading = false;
            lock (dfLk)
            {
                if (cancelled) { dfStatus.state = "cancelled"; try { File.Delete(path); } catch { } }
                else if (err != null) { dfStatus.state = "error"; dfStatus.error = err; }
                else dfStatus.state = "done";
            }
        }
    }

    public void DfCancel() { try { dfCts?.Cancel(); } catch { } }
    public void DfErase() { Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.LOG_ERASE, new mavlink_log_erase_t(targetSys, targetComp), false, 255, 190, 0)); lock (dfLk) dfEntries.Clear(); }
}
