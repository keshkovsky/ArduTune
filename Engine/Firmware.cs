using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.IO.Ports;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using static MAVLink;

/// Встановлення прошивки: каталог з firmware.ardupilot.org, завантаження .apj і прошивання через завантажувач (протокол PX4/ArduPilot bootloader).
class FwStatus
{
    public string state = "idle";       // idle | running | done | error | cancelled
    public string stage = "";
    public double progress;
    public List<string> log = new List<string>();
    public string error;
    public int boardId; public string port;
}

partial class Link
{
    static readonly HttpClient http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
    static string FwDir { get { var d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ArduTune", "Firmware"); Directory.CreateDirectory(d); return d; } }
    public readonly FwStatus Fw = new FwStatus();
    bool IsConnected { get { lock (lk) return T.connected; } }
    CancellationTokenSource fwCts;

    // ---------- Каталог ----------
    static string manifestCache;
    static List<JsonElement> allCache;

    /// Усі версії прошивки для плати (latest, beta і всі випуски stable-X.Y.Z).
    public static async Task<string> FwVersions(string vehicle, string platform)
    {
        var path = Path.Combine(FwDir, "manifest.all.json");
        if (!File.Exists(path)) await FwManifest(true);
        if (allCache == null) { using var d = JsonDocument.Parse(File.ReadAllText(path)); allCache = d.RootElement.EnumerateArray().Select(x => x.Clone()).ToList(); }
        var res = allCache.Where(x => x.GetProperty("vehicle").GetString() == vehicle && x.GetProperty("platform").GetString() == platform && x.GetProperty("type").GetString() != "OFFICIAL" && x.TryGetProperty("format", out _))
            .Select(x => JsonSerializer.Deserialize<object>(x.GetRawText())).ToList();
        return JsonSerializer.Serialize(res);
    }

    /// Спрощений каталог: лише .apj і найновіші збірки (latest) за типом і платою.
    public static async Task<string> FwManifest(bool force)
    {
        var path = Path.Combine(FwDir, "manifest.json");
        if (!force && manifestCache != null) return manifestCache;
        if (!force && File.Exists(path) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(path)).TotalHours < 6) return manifestCache = File.ReadAllText(path);
        try
        {
            using var resp = await http.GetAsync("https://firmware.ardupilot.org/manifest.json.gz");
            resp.EnsureSuccessStatusCode();
            await using var gz = new GZipStream(await resp.Content.ReadAsStreamAsync(), CompressionMode.Decompress);
            using var doc = await JsonDocument.ParseAsync(gz);
            var list = new List<object>(); var all = new List<object>();
            foreach (var f in doc.RootElement.GetProperty("firmware").EnumerateArray())
            {
                string S(string k) => f.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : "";
                var fmt = S("format");
                if (fmt != "apj" && !(fmt == "hex" && S("url").EndsWith("_with_bl.hex"))) continue;      // apj для завантажувача, hex із завантажувачем для DFU
                var ty = S("mav-firmware-version-type");
                int bid = f.TryGetProperty("board_id", out var b) && b.ValueKind == JsonValueKind.Number ? b.GetInt32() : 0;
                var e = new { format = fmt, vehicle = S("vehicletype"), platform = S("platform"), boardId = bid, version = S("mav-firmware-version"), type = ty, frame = S("frame"), url = S("url"), git = S("git-sha"), mav = S("mav-type") };
                if (ty == "OFFICIAL" || ty == "BETA" || ty == "DEV") list.Add(e);                  // папки stable / beta / latest
                if (ty == "OFFICIAL" || ty == "BETA" || ty == "DEV" || ty.StartsWith("STABLE-")) all.Add(e);   // усі випуски
            }
            File.WriteAllText(Path.Combine(FwDir, "manifest.all.json"), JsonSerializer.Serialize(all.Distinct().ToList()));
            allCache = null;
            var json = JsonSerializer.Serialize(list.Distinct().ToList());
            File.WriteAllText(path, json);
            return manifestCache = json;
        }
        catch when (File.Exists(path)) { return manifestCache = File.ReadAllText(path); }       // немає мережі: застарілий кеш
    }

    public static async Task<string> FwDownload(string url)
    {
        var u = new Uri(url);
        if (u.Scheme != "https" || (u.Host != "firmware.ardupilot.org" && u.Host != "firmware.ardupilot.org".Replace("firmware.", "")))
            throw new Exception("Дозволено завантажувати лише з firmware.ardupilot.org");
        var name = Path.GetFileName(u.LocalPath);
        var sub = string.Join("_", u.AbsolutePath.Trim('/').Split('/').SkipLast(1).TakeLast(3));
        var dest = Path.Combine(FwDir, sub + "__" + name);
        var data = await http.GetByteArrayAsync(u);
        if (data.Length < 1024) throw new Exception("Файл прошивки порожній або пошкоджений");
        File.WriteAllBytes(dest, data);
        return dest;
    }

    public static object FwInspect(string path)
    {
        if (path.EndsWith(".hex", StringComparison.OrdinalIgnoreCase))
            return new { path, boardId = 0, size = (int)new FileInfo(path).Length, summary = "Intel HEX із завантажувачем (для DFU)", version = "" };
        var fw = LoadFirmware(path);
        return new { path, boardId = fw.boardId, size = fw.image.Length, summary = fw.summary, version = fw.version };
    }

    // ---------- Файли прошивки ----------
    static (byte[] image, int boardId, string summary, string version) LoadFirmware(string path)
    {
        var bytes = File.ReadAllBytes(path);
        if (path.EndsWith(".apj", StringComparison.OrdinalIgnoreCase))
        {
            using var doc = JsonDocument.Parse(bytes);
            var r = doc.RootElement;
            var raw = Convert.FromBase64String(r.GetProperty("image").GetString());
            using var ms = new MemoryStream(raw); using var z = new ZLibStream(ms, CompressionMode.Decompress); using var o = new MemoryStream();
            z.CopyTo(o);
            var img = o.ToArray();
            int size = r.TryGetProperty("image_size", out var sz) ? sz.GetInt32() : img.Length;
            if (size > 0 && size <= img.Length) img = img.Take(size).ToArray();
            string S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : "";
            return (img, r.TryGetProperty("board_id", out var b) ? b.GetInt32() : 0, S("summary"), S("version"));
        }
        if (path.EndsWith(".abin", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".bin", StringComparison.OrdinalIgnoreCase)) return (bytes, 0, "сирий образ", "");
        throw new Exception("Підтримуються файли .apj і .bin");
    }

    // ---------- Протокол завантажувача ----------
    const byte INSYNC = 0x12, EOC = 0x20, OK = 0x10, FAILED = 0x11, INVALID = 0x13, BAD_SILICON = 0x14;
    const byte GET_SYNC = 0x21, GET_DEVICE = 0x22, CHIP_ERASE = 0x23, PROG_MULTI = 0x27, GET_CRC = 0x29, REBOOT = 0x30;
    const byte INFO_BL_REV = 1, INFO_BOARD_ID = 2, INFO_FLASH_SIZE = 4;

    static uint Crc32(byte[] data, uint state)
    {
        foreach (var b in data) { state ^= b; for (int k = 0; k < 8; k++) state = (state & 1) != 0 ? (state >> 1) ^ 0xEDB88320u : state >> 1; }
        return state;
    }

    static byte[] Recv(SerialPort sp, int n, int timeoutMs)
    {
        var buf = new byte[n]; int got = 0; var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (got < n)
        {
            if (DateTime.UtcNow > until) throw new TimeoutException("Завантажувач не відповів");
            if (sp.BytesToRead > 0) got += sp.Read(buf, got, Math.Min(n - got, sp.BytesToRead)); else Thread.Sleep(2);
        }
        return buf;
    }
    static void GetSync(SerialPort sp, int timeoutMs = 1000)
    {
        var r = Recv(sp, 2, timeoutMs);
        if (r[0] != INSYNC) throw new Exception($"Немає синхронізації з завантажувачем (0x{r[0]:X2})");
        if (r[1] == INVALID) throw new Exception("Завантажувач: неприпустима команда");
        if (r[1] == FAILED) throw new Exception("Завантажувач: помилка виконання");
        if (r[1] == BAD_SILICON) throw new Exception("Завантажувач: ця ревізія мікросхеми не підтримується");
        if (r[1] != OK) throw new Exception($"Завантажувач відповів 0x{r[1]:X2}");
    }
    static bool TrySync(SerialPort sp)
    {
        for (int i = 0; i < 3; i++)
        {
            try { sp.DiscardInBuffer(); sp.Write(new[] { GET_SYNC, EOC }, 0, 2); GetSync(sp, 400); return true; } catch { }
        }
        return false;
    }
    static uint Info(SerialPort sp, byte what)
    {
        sp.DiscardInBuffer(); sp.Write(new[] { GET_DEVICE, what, EOC }, 0, 3);
        var r = Recv(sp, 4, 1500); GetSync(sp); return BitConverter.ToUInt32(r, 0);
    }

    void FwLog(string s) { lock (Fw) { Fw.log.Add(s); if (Fw.log.Count > 300) Fw.log.RemoveAt(0); } }
    void FwStage(string s, double p = -1, bool log = true) { lock (Fw) { Fw.stage = s; if (p >= 0) Fw.progress = p; } if (log) FwLog(s); }

    public bool FwStart(string path, string port, bool force)
    {
        lock (Fw) { if (Fw.state == "running") return false; Fw.state = "running"; Fw.stage = "Підготовка"; Fw.progress = 0; Fw.log.Clear(); Fw.error = null; Fw.boardId = 0; Fw.port = null; }
        fwCts = new CancellationTokenSource(); var ct = fwCts.Token;
        Task.Run(() =>
        {
            SerialPort sp = null;
            try
            {
                var fw = LoadFirmware(path);
                FwLog($"Файл: {Path.GetFileName(path)}, образ {fw.image.Length / 1024} КБ, board_id {fw.boardId}");
                // без board_id (сирий .bin або .apj без поля) перевірити відповідність платі неможливо: лише з явним дозволом
                if (fw.boardId == 0 && !force) throw new Exception("У файлі немає board_id: неможливо перевірити, що прошивка для цієї плати. Прошивання скасовано. Якщо ви впевнені, увімкніть дозвіл на невідповідність.");
                // 1. Якщо автопілот підключено й працює, просимо перезавантажитись у завантажувач
                bool wasConnected = Armed || IsConnected;
                if (wasConnected)
                {
                    if (Armed) throw new Exception("Апарат ARMED: прошивання заблоковано");
                    FwStage("Перезавантаження автопілота в режим завантажувача…", 0.02);
                    Cmd(MAV_CMD.PREFLIGHT_REBOOT_SHUTDOWN, 3);
                    Thread.Sleep(600);
                    Disconnect();
                    Thread.Sleep(1500);
                }
                // 2. Пошук завантажувача
                FwStage("Пошук завантажувача на USB-портах (до 30 с). Якщо плата не відповідає, відключіть її й підключіть знову.", 0.04);
                var until = DateTime.UtcNow.AddSeconds(30);
                string found = null;
                while (DateTime.UtcNow < until && found == null)
                {
                    ct.ThrowIfCancellationRequested();
                    // явно вибраний порт: лише він (інші пристрої не зондуємо); інакше всі USB-порти
                    var cands = new List<string>();
                    if (!string.IsNullOrEmpty(port) && File.Exists(port)) cands.Add(port);
                    else cands.AddRange(Directory.GetFiles("/dev", "cu.usbmodem*").Concat(Directory.GetFiles("/dev", "cu.usbserial*")));
                    // скануємо ВСІ кандидати: два завантажувачі одночасно означають ризик прошити не ту плату
                    var syncing = new List<string>();
                    foreach (var c in cands)
                    {
                        SerialPort probe = null;
                        try
                        {
                            probe = new SerialPort(c, 115200) { ReadTimeout = 500, WriteTimeout = 1000, DtrEnable = false, RtsEnable = false };
                            probe.Open();
                            if (TrySync(probe)) syncing.Add(c);
                        }
                        catch { }
                        finally { try { probe?.Close(); probe?.Dispose(); } catch { } }
                    }
                    if (syncing.Count > 1) throw new Exception("Завантажувач відповідає на кількох портах (" + string.Join(", ", syncing.Select(Path.GetFileName)) + "): можливо, підключено кілька плат. Відключіть зайві й повторіть, щоб не прошити не ту.");
                    if (syncing.Count == 1)
                    {
                        try
                        {
                            sp = new SerialPort(syncing[0], 115200) { ReadTimeout = 500, WriteTimeout = 1000, DtrEnable = false, RtsEnable = false };
                            sp.Open();
                            if (TrySync(sp)) found = syncing[0]; else { sp.Close(); sp.Dispose(); sp = null; }
                        }
                        catch { try { sp?.Dispose(); } catch { } sp = null; }
                    }
                    if (found == null) Thread.Sleep(400);
                }
                if (found == null) throw new Exception("Завантажувач не знайдено. Підключіть плату знову (з утриманою кнопкою boot, якщо вона є) і повторіть.");
                lock (Fw) Fw.port = found;
                FwLog("Завантажувач знайдено: " + found);
                // 3. Інформація про плату
                uint blRev = Info(sp, INFO_BL_REV), boardId = Info(sp, INFO_BOARD_ID), flash = Info(sp, INFO_FLASH_SIZE);
                lock (Fw) Fw.boardId = (int)boardId;
                FwLog($"Завантажувач rev {blRev}, board_id {boardId}, флеш {flash / 1024} КБ");
                if (fw.boardId != 0 && fw.boardId != (int)boardId && !force) throw new Exception($"Прошивка для board_id {fw.boardId}, а підключена плата має {boardId}. Прошивання скасовано, щоб не пошкодити плату.");
                if (fw.image.Length > flash) throw new Exception("Прошивка більша за флеш-пам'ять плати");
                if (blRev < 3 || blRev > 5) FwLog("Увага: нетипова ревізія завантажувача " + blRev);
                // 4. Стирання
                ct.ThrowIfCancellationRequested();
                FwStage("Стирання флеш-пам'яті (до 30 с)…", 0.08);
                sp.DiscardInBuffer(); sp.Write(new[] { CHIP_ERASE, EOC }, 0, 2); GetSync(sp, 60000);
                // 5. Запис
                var img = fw.image.ToList(); while (img.Count % 4 != 0) img.Add(0xFF);
                var data = img.ToArray();
                const int Chunk = 252;
                for (int off = 0; off < data.Length; off += Chunk)
                {
                    ct.ThrowIfCancellationRequested();
                    int n = Math.Min(Chunk, data.Length - off);
                    var pkt = new byte[n + 3]; pkt[0] = PROG_MULTI; pkt[1] = (byte)n; Array.Copy(data, off, pkt, 2, n); pkt[n + 2] = EOC;
                    sp.Write(pkt, 0, pkt.Length); GetSync(sp, 4000);
                    if ((off / Chunk) % 16 == 0) FwStage($"Запис: {(off + n) / 1024} з {data.Length / 1024} КБ", 0.1 + 0.8 * (off + n) / data.Length, false);
                }
                // 6. Перевірка CRC
                FwStage("Перевірка контрольної суми…", 0.92);
                uint crc = Crc32(data, 0);
                var pad = new byte[4] { 0xFF, 0xFF, 0xFF, 0xFF };
                for (long i = data.Length; i < flash; i += 4) crc = Crc32(pad, crc);
                sp.DiscardInBuffer(); sp.Write(new[] { GET_CRC, EOC }, 0, 2);
                var rc = Recv(sp, 4, 15000); GetSync(sp);
                uint got = BitConverter.ToUInt32(rc, 0);
                if (got != crc) throw new Exception($"Контрольна сума не збіглась (плата {got:X8}, очікувалось {crc:X8}). Повторіть прошивання.");
                // 7. Перезавантаження
                FwStage("Перезавантаження плати…", 0.98);
                sp.Write(new[] { REBOOT, EOC }, 0, 2);
                try { GetSync(sp, 1000); } catch { }
                lock (Fw) { Fw.state = "done"; Fw.progress = 1; Fw.stage = "Готово: прошивку встановлено"; }
                FwLog("Готово");
            }
            catch (OperationCanceledException) { lock (Fw) { Fw.state = "cancelled"; Fw.stage = "Скасовано"; } FwLog("Скасовано користувачем (плата лишається в завантажувачі, її можна прошити знову)"); }
            catch (Exception e) { lock (Fw) { Fw.state = "error"; Fw.error = e.Message; } FwLog("Помилка: " + e.Message); }
            finally { try { sp?.Close(); sp?.Dispose(); } catch { } }
        });
        return true;
    }
    public void FwCancel() { try { fwCts?.Cancel(); } catch { } }
    public object FwState() { lock (Fw) return new { Fw.state, Fw.stage, Fw.progress, Fw.error, Fw.boardId, Fw.port, log = Fw.log.TakeLast(60).ToList() }; }
    public static string[] UsbPorts() => Directory.GetFiles("/dev", "cu.usb*").OrderBy(x => x).ToArray();
}
