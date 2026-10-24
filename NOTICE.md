# ArduTune

Copyright (C) 2026 keshkovsky. Розповсюджується за GNU General Public License v3 (див. LICENSE).

## Сторонні компоненти і джерела
- `ExtLibs/Mavlink`: MAVLink для C#, Michael Oborne (проєкт Mission Planner), GPLv3.
- Метадані параметрів `apm.pdef.xml`, схеми моторів (AP_MotorsMatrix.cpp), таблиці device ID і SERIAL (hwdef): ArduPilot, GPLv3.
- GStreamer (LGPL): окремий процес, не вбудований.
- .NET runtime (MIT), System.IO.Ports (MIT).
- Шрифти екранного меню `MacApp/Resources/osdfonts/font0…4.bin` та коди символів і формати елементів OSD (за AP_OSD_Screen.cpp): ArduPilot (libraries/AP_OSD), GPLv3; шрифти походять від проєкту inavosd (iNavFlight/inav-configurator).
