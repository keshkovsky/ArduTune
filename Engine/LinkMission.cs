using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using static MAVLink;

/// Елемент місії для обміну із застосунком (JSON). Координати в градусах, висота в метрах.
public class MItem
{
    public int seq { get; set; }
    public int cmd { get; set; }
    public int frame { get; set; }
    public double p1 { get; set; }
    public double p2 { get; set; }
    public double p3 { get; set; }
    public double p4 { get; set; }
    public double lat { get; set; }
    public double lon { get; set; }
    public double alt { get; set; }
    public bool auto { get; set; } = true;
}

/// Протокол місій MAVLink (MISSION_COUNT / MISSION_REQUEST_INT / MISSION_ITEM_INT / MISSION_ACK).
/// Поля розбираються з сирих байтів: рефлексія на packed-структурах небезпечна на Apple Silicon.
partial class Link
{
    readonly BlockingCollection<(int id, byte[] p)> mRx = new BlockingCollection<(int, byte[])>(new ConcurrentQueue<(int, byte[])>(), 2048);
    readonly SemaphoreSlim mLock = new SemaphoreSlim(1, 1);

    void MissionIntercept(MAVLinkMessage m)
    {
        switch ((MAVLINK_MSG_ID)m.msgid)
        {
            case MAVLINK_MSG_ID.MISSION_COUNT:
            case MAVLINK_MSG_ID.MISSION_ITEM_INT:
            case MAVLINK_MSG_ID.MISSION_REQUEST_INT:
            case MAVLINK_MSG_ID.MISSION_REQUEST:
            case MAVLINK_MSG_ID.MISSION_ACK:
                mRx.TryAdd(((int)m.msgid, Pad(Payload(m), 40)));
                break;
        }
    }

    static string MissionResult(int c) => c switch
    {
        1 => "помилка", 2 => "непідтримувана система координат", 3 => "команда не підтримується", 4 => "немає місця в пам'яті польотника",
        5 => "некоректний елемент", 6 => "некоректний параметр 1", 7 => "некоректний параметр 2", 8 => "некоректний параметр 3", 9 => "некоректний параметр 4",
        10 => "некоректна широта (X)", 11 => "некоректна довгота (Y)", 12 => "некоректна висота (Z)", 13 => "не той апарат", 14 => "некоректний номер елемента",
        15 => "відхилено польотником", 16 => "операція скасована", _ => "код " + c,
    };

    bool MWait(int id, int timeoutMs, Func<byte[], bool> ok, out byte[] got)
    {
        var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (true)
        {
            var left = (int)(until - DateTime.UtcNow).TotalMilliseconds;
            if (left <= 0) { got = null; return false; }
            if (!mRx.TryTake(out var r, left)) { got = null; return false; }
            if (r.id == id && ok(r.p)) { got = r.p; return true; }
        }
    }

    public List<MItem> MissionDownload(byte mt = 0)
    {
        mLock.Wait();
        try
        {
            while (mRx.TryTake(out _)) { }
            int count = -1;
            for (int a = 0; a < 5 && count < 0; a++)
            {
                Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_REQUEST_LIST, new mavlink_mission_request_list_t(targetSys, targetComp, mt), false, 255, 190, 0));
                if (MWait((int)MAVLINK_MSG_ID.MISSION_COUNT, 1500, p => p[4] == mt, out var c)) count = BitConverter.ToUInt16(c, 0);
            }
            if (count < 0) throw new Exception("Польотник не відповів на запит місії");
            var res = new List<MItem>();
            for (int seq = 0; seq < count; seq++)
            {
                byte[] it = null;
                for (int a = 0; a < 6 && it == null; a++)
                {
                    Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_REQUEST_INT, new mavlink_mission_request_int_t((ushort)seq, targetSys, targetComp, mt), false, 255, 190, 0));
                    if (MWait((int)MAVLINK_MSG_ID.MISSION_ITEM_INT, 1200, p => BitConverter.ToUInt16(p, 28) == seq && p[37] == mt, out var r)) it = r;
                }
                if (it == null) throw new Exception($"Елемент {seq} не отримано");
                res.Add(new MItem
                {
                    seq = seq, p1 = BitConverter.ToSingle(it, 0), p2 = BitConverter.ToSingle(it, 4), p3 = BitConverter.ToSingle(it, 8), p4 = BitConverter.ToSingle(it, 12),
                    lat = BitConverter.ToInt32(it, 16) / 1e7, lon = BitConverter.ToInt32(it, 20) / 1e7, alt = BitConverter.ToSingle(it, 24),
                    cmd = BitConverter.ToUInt16(it, 30), frame = it[34], auto = it[36] != 0,
                });
            }
            Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_ACK, new mavlink_mission_ack_t(targetSys, targetComp, 0, mt), false, 255, 190, 0));
            return res;
        }
        finally { mLock.Release(); }
    }

    public void MissionUpload(List<MItem> items, byte mt = 0)
    {
        mLock.Wait();
        try
        {
            while (mRx.TryTake(out _)) { }
            int n = items.Count;
            void SendCount() => Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_COUNT, new mavlink_mission_count_t((ushort)n, targetSys, targetComp, mt), false, 255, 190, 0));
            void SendItem(int seq)
            {
                var i = items[seq];
                Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_ITEM_INT,
                    new mavlink_mission_item_int_t((float)i.p1, (float)i.p2, (float)i.p3, (float)i.p4, (int)Math.Round(i.lat * 1e7), (int)Math.Round(i.lon * 1e7), (float)i.alt,
                        (ushort)seq, (ushort)i.cmd, targetSys, targetComp, (byte)i.frame, (byte)(seq == 0 && mt == 0 ? 1 : 0), (byte)(i.auto ? 1 : 0), mt), false, 255, 190, 0));
            }
            SendCount();
            var deadline = DateTime.UtcNow.AddSeconds(90); int silent = 0;
            while (DateTime.UtcNow < deadline)
            {
                if (!mRx.TryTake(out var r, 1500)) { if (++silent > 5) throw new Exception("Польотник не відповідає під час запису місії"); SendCount(); continue; }
                silent = 0;
                if (r.id == (int)MAVLINK_MSG_ID.MISSION_REQUEST_INT || r.id == (int)MAVLINK_MSG_ID.MISSION_REQUEST)
                {
                    if (r.p[4] != mt && r.id == (int)MAVLINK_MSG_ID.MISSION_REQUEST_INT) continue;
                    int seq = BitConverter.ToUInt16(r.p, 0);
                    if (seq >= 0 && seq < n) SendItem(seq);
                }
                else if (r.id == (int)MAVLINK_MSG_ID.MISSION_ACK)
                {
                    if (r.p[3] != mt) continue;       // ACK іншого типу місії
                    int t = r.p[2];
                    if (t == 0) return;
                    throw new Exception("Польотник відхилив місію: " + MissionResult(t));
                }
            }
            throw new Exception("Час запису місії вичерпано");
        }
        finally { mLock.Release(); }
    }

    public void MissionClear(byte mt = 0)
    {
        mLock.Wait();
        try
        {
            while (mRx.TryTake(out _)) { }
            for (int a = 0; a < 4; a++)
            {
                Send(gen.GenerateMAVLinkPacket20(MAVLINK_MSG_ID.MISSION_CLEAR_ALL, new mavlink_mission_clear_all_t(targetSys, targetComp, mt), false, 255, 190, 0));
                if (MWait((int)MAVLINK_MSG_ID.MISSION_ACK, 1500, p => p[3] == mt, out var r)) { if (r[2] == 0) return; throw new Exception("Польотник відхилив очищення: " + MissionResult(r[2])); }
            }
            throw new Exception("Польотник не підтвердив очищення місії");
        }
        finally { mLock.Release(); }
    }

    public void MissionSetCurrent(int seq) => Cmd(MAV_CMD.DO_SET_MISSION_CURRENT, seq);
}
