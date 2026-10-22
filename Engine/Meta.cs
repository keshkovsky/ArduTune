using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using System.Xml.Linq;

// Метадані параметрів ArduCopter (описи, одиниці, діапазони) з офіційного apm.pdef.xml.
class MetaItem
{
    public string name { get; set; }
    public string label { get; set; }
    public string doc { get; set; }
    public string units { get; set; }
    public double? min { get; set; }
    public double? max { get; set; }
    public double? inc { get; set; }
    public string[][] values { get; set; }
    public string[][] bits { get; set; }
    public bool readOnly { get; set; }
    public bool reboot { get; set; }
    public string user { get; set; }
}

static class Meta
{
    static string dir = "ArduCopter";
    static string json = "[]";
    static int generation;
    static readonly object gate = new object();
    public static string Json => json;
    public static string Dir => dir;
    public static string Status = "loading";

    /// Каталог метаданих за типом апарата з MAVLink (MAV_TYPE).
    public static string DirFor(string vehicle)
    {
        if ((vehicle ?? "").StartsWith("VTOL")) return "ArduPlane";
        switch (vehicle ?? "")
        {
            case "FIXED_WING": case "FLAPPING_WING": return "ArduPlane";
            case "GROUND_ROVER": case "SURFACE_BOAT": return "Rover";
            case "SUBMARINE": return "ArduSub";
            case "ANTENNA_TRACKER": return "AntennaTracker";
            case "": return null;
            default: return "ArduCopter";
        }
    }

    static string CacheFor(string d)
    {
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ArduTune");
        Directory.CreateDirectory(folder);
        return Path.Combine(folder, d + ".pdef.xml");
    }

    /// Перемикає метадані на потрібний тип апарата (викликається при першому heartbeat і зміні типу).
    public static void ForVehicle(string vehicle)
    {
        var d = DirFor(vehicle);
        if (d == null) return;
        lock (gate) { if (d == dir && generation > 0) return; dir = d; json = "[]"; Status = "loading"; generation++; }
        _ = Task.Run(() => LoadAsync(d, generation));
    }

    /// Явний вибір каталогу метаданих (перегляд файлу параметрів без підключеного польотника).
    public static bool ForDir(string d)
    {
        if (d != "ArduCopter" && d != "ArduPlane" && d != "Rover" && d != "ArduSub" && d != "AntennaTracker") return false;
        lock (gate) { if (d == dir && generation > 0) return true; dir = d; json = "[]"; Status = "loading"; generation++; }
        _ = Task.Run(() => LoadAsync(d, generation));
        return true;
    }

    public static Task LoadAsync() { lock (gate) { generation++; return LoadAsync(dir, generation); } }

    // ---- Версія прошивки ----
    static (int M, int m, int p, int type)? fwVer;
    public static string Source = "";          // що саме використано для описів (показується в застосунку)

    /// Версія прошивки плати (з AUTOPILOT_VERSION або STATUSTEXT): метадані підбираються під неї.
    public static void ForVersion(int major, int minor, int patch, int type)
    {
        lock (gate)
        {
            if (fwVer.HasValue && fwVer.Value == (major, minor, patch, type)) return;
            fwVer = (major, minor, patch, type);
            generation++;
        }
        var d = dir; int g; lock (gate) g = generation;
        _ = Task.Run(() => LoadAsync(d, g));
    }
    public static void ResetVersion() { lock (gate) { fwVer = null; } }

    /// Назва каталогу версій на autotest.ardupilot.org.
    static string VersionedDir(string d) => d switch { "ArduCopter" => "Copter", "ArduPlane" => "Plane", "Rover" => "Rover", "ArduSub" => "Sub", "AntennaTracker" => "Tracker", _ => null };

    static async Task<List<(int M, int m, int p)>> StableTags(HttpClient http, string vdir)
    {
        var file = Path.Combine(Path.GetDirectoryName(CacheFor("x")), $"versions.{vdir}.txt");
        string html = null;
        if (File.Exists(file) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(file)).TotalHours < 24) html = File.ReadAllText(file);
        else
        {
            try { html = await http.GetStringAsync($"https://autotest.ardupilot.org/Parameters/versioned/{vdir}/"); File.WriteAllText(file, html); }
            catch { if (File.Exists(file)) html = File.ReadAllText(file); }
        }
        var res = new List<(int, int, int)>();
        if (html == null) return res;
        foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(html, @"href=""stable-(\d+)\.(\d+)\.(\d+)/"""))
            res.Add((int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value)));
        return res.Distinct().OrderBy(x => x).ToList();
    }

    static async Task<string> FetchPdef(HttpClient http, string cache, string url, bool preferCache)
    {
        if (preferCache && File.Exists(cache)) return File.ReadAllText(cache);
        try { var xml = await http.GetStringAsync(url); File.WriteAllText(cache, xml); return xml; }
        catch { return File.Exists(cache) ? File.ReadAllText(cache) : null; }
    }

    static async Task LoadAsync(string d, int gen)
    {
        try
        {
            var vdir = VersionedDir(d);
            (int M, int m, int p, int type)? ver; lock (gate) ver = fwVer;
            // 0) Миттєво віддаємо кеш «latest», поки йде вибір версії
            var latestCache = CacheFor(d);
            var merged = new Dictionary<string, MetaItem>();
            void Publish(string source)
            {
                var j = JsonSerializer.Serialize(merged.Values.OrderBy(x => x.name).ToList());
                lock (gate) { if (gen == generation) { json = j; Source = source; Status = "online"; } }
            }
            void Merge(string xml) { foreach (var it in Parse(xml, d)) if (!merged.ContainsKey(it.name)) merged[it.name] = it; }
            if (File.Exists(latestCache) && ver == null) { try { Merge(File.ReadAllText(latestCache)); Publish("latest (кеш)"); lock (gate) { if (gen == generation) Status = "cache"; } } catch { } }

            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(90) };
            string primary = "latest";
            string prevKey = null, prevUrl = null; string primKey = null, primUrl = null;
            if (ver != null && vdir != null)
            {
                var tags = await StableTags(http, vdir);
                var v = ver.Value; bool dev = v.type == 0 || v.type == 64;           // 0 = dev, 64 = alpha
                (int M, int m, int p)? pick = null;
                if (dev) { if (tags.Contains((v.M, v.m, 0))) pick = (v.M, v.m, 0); }       // 4.7.0-dev: описи релізу 4.7.0 найближчі
                else
                {
                    var le = tags.Where(t => t.CompareTo((v.M, v.m, v.p)) <= 0).ToList();
                    if (le.Count > 0) pick = le.Last();
                }
                if (pick.HasValue) { primary = $"stable-{pick.Value.M}.{pick.Value.m}.{pick.Value.p}"; primKey = primary; primUrl = $"https://autotest.ardupilot.org/Parameters/versioned/{vdir}/{primary}/apm.pdef.xml"; }
                var prev = tags.Where(t => (t.M, t.m).CompareTo((v.M, v.m)) < 0).ToList();
                if (prev.Count > 0) { var pv = prev.Last(); prevKey = $"stable-{pv.M}.{pv.m}.{pv.p}"; prevUrl = $"https://autotest.ardupilot.org/Parameters/versioned/{vdir}/{prevKey}/apm.pdef.xml"; }
            }
            var folder = Path.GetDirectoryName(latestCache);
            // 1) Основне джерело: версія прошивки (або latest, якщо версія невідома / не випущена)
            if (primKey != null)
            {
                var xml = await FetchPdef(http, Path.Combine(folder, $"{d}.{primKey}.pdef.xml"), primUrl, true);
                if (xml != null) { Merge(xml); Publish(primary); }
            }
            // 2) latest (master): нові параметри й, для невідомої версії, основне джерело
            var lx = await FetchPdef(http, latestCache, $"https://autotest.ardupilot.org/Parameters/{d}/apm.pdef.xml", false);
            if (lx != null) { Merge(lx); if (primKey == null || prevKey == null) Publish(primKey != null ? primary + " + latest" : "latest"); }
            // 3) попередній випуск: старі назви параметрів, яких уже немає в новому
            if (prevKey != null)
            {
                var px = await FetchPdef(http, Path.Combine(folder, $"{d}.{prevKey}.pdef.xml"), prevUrl, true);
                if (px != null) { Merge(px); Publish((primKey ?? "latest") + (primKey != null ? " + latest" : "") + " + " + prevKey); }
            }
            if (merged.Count == 0) lock (gate) { if (gen == generation && json == "[]") Status = "unavailable: немає ні кешу, ні мережі"; }
        }
        catch (Exception e)
        {
            lock (gate) { if (gen == generation && json == "[]") Status = "unavailable: " + e.Message; }
        }
    }

    static string[][] Pairs(string s) =>
        s.Split(',').Select(x => x.Split(new[] { ':' }, 2)).Where(a => a.Length == 2).Select(a => new[] { a[0].Trim(), a[1].Trim() }).ToArray();

    static List<MetaItem> Parse(string xml, string vehicleDir)
    {
        var res = new Dictionary<string, MetaItem>();
        foreach (var p in XDocument.Parse(xml).Descendants("param"))
        {
            var full = (string)p.Attribute("name") ?? "";
            var name = full;
            var i = full.IndexOf(':');
            if (i >= 0)
            {
                if (full.Substring(0, i) != vehicleDir) continue; // чужі апарати пропускаємо
                name = full.Substring(i + 1);
            }
            var it = new MetaItem
            {
                name = name,
                label = (string)p.Attribute("humanName"),
                doc = (string)p.Attribute("documentation"),
                user = (string)p.Attribute("user")
            };
            foreach (var f in p.Elements("field"))
            {
                var v = ((string)f).Trim();
                switch ((string)f.Attribute("name"))
                {
                    case "Units": it.units = v; break;
                    case "Range":
                        var r = v.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                        if (r.Length == 2 && double.TryParse(r[0], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var a) &&
                            double.TryParse(r[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var b)) { it.min = a; it.max = b; }
                        break;
                    case "Increment":
                        if (double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var inc)) it.inc = inc;
                        break;
                    case "Bitmask": it.bits = Pairs(v); break;
                    case "ReadOnly": it.readOnly = v.ToLower() == "true"; break;
                    case "RebootRequired": it.reboot = v.ToLower() == "true"; break;
                }
            }
            var vals = p.Element("values");
            if (vals != null) it.values = vals.Elements("value").Select(x => new[] { ((string)x.Attribute("code")), x.Value.Trim() }).ToArray();
            res[name] = it;
        }
        return res.Values.OrderBy(x => x.name).ToList();
    }
}
