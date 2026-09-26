# LifetimePhotometry

Frequency-domain fluorescence lifetime photometry acquisition in MATLAB.

Drives a four-phase homodyne FLIM rig: sweeps the phase shifter to calibrate
the mixer channels, then records lifetime, intensity and phasor coordinates in
real time while writing the raw inputs to disk.

## Requirements

**MATLAB R2026a**, with:

| Toolbox | Needed for |
| --- | --- |
| Statistics and Machine Learning | `normpdf`, `range` — core analysis |
| Signal Processing | `hann` — the dark calibration's noise spectrum |
| Data Acquisition | National Instruments backend only |

Hardware drivers, by backend:

- **National Instruments** — NI-DAQmx 26.5.0 or newer. MATLAB's DAQ adaptor
  talks to it directly; there is no separate hardware support package to
  install on R2026a. Install the driver before first use, or restart MATLAB
  afterwards so it is detected.
- **LabJack T7** — LabJack LJM (`LabJack.LJM.dll`, registered in the GAC).
- **Simulated** — nothing. Synthesises a complete rig in software.

The Thorlabs PMT2100 detector control additionally needs the vendor SDK at
`C:\Program Files\Thorlabs\PMT2100 4.0`.

## Getting started

Add the repository and `pmt/` to the MATLAB path, then run:

```matlab
FLIMIR_DataAcq
```

The app asks for a settings file on startup. `FLIMIR_default_settings.json`
is a working default that selects the simulated backend, so the application
runs with no hardware attached. Point `saveDirectory` at a real folder and
re-save, and Setup will run automatically on the next launch.

Order of operations on a real rig: **Dark** (offsets, with the beam blocked),
then **Calibrate** (phase shifter sweep), then **Start**. Without a mixer
calibration the app still records everything but displays intensity only.

## Channel map

Analog inputs, in the order the analysis expects them:

| Channel | Signal |
| --- | --- |
| `ai0`–`ai3` | VIF1–VIF4, the four mixer channels at 0°, 90°, 180°, 270° |
| `ai4` | VDC, the DC/intensity channel |
| `ai5` | phase shifter loopback (optional) — scored against the command, never used as the phase axis |

Outputs: `ao0` laser power, `ao1` phase shifter, `port0/line0` shutter TTL.

## Layout

```
FLIMIR_DataAcq.m              application: GUI, acquisition, plotting
FlimirDaqDevice.m             abstract backend interface
FlimirDaqNI.m                 National Instruments
FlimirDaqLabJack.m            LabJack T7
FlimirDaqSimulated.m          synthetic two-state FLIM rig
calibration.m                 phase shifter sweep, multi-speed or averaged
dark_calibration.m            channel offsets with the beam blocked
calculate_phase_calibration.m sweep -> mixer calibration
calculate_tau_s_g.m           per-block lifetime and phasor
flimir_*.m                    shared helpers
pmt/                          Thorlabs PMT2100 control
```

Backends are discovered by reflection: a new subclass of `FlimirDaqDevice`
placed on the path appears in the Backend menu with no other change.

## The PMT shim

`pmt/ThorPmtShim.dll` is a small P/Invoke wrapper over the Thorlabs C SDK. It
exists because MATLAB's `loadlibrary` needs a configured C compiler and cannot
parse the vendor header, which declares C++ reference parameters. The DLL is
committed so the project runs as-is; to rebuild it from `ThorPmtShim.cs` with
the compiler that ships with Windows:

```
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:library /platform:x64 /out:ThorPmtShim.dll ThorPmtShim.cs
```
