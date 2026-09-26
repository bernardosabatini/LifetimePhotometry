// ThorPmtShim.cs - P/Invoke shim over Thorlabs' ThorPMT2100.dll
//
// WHY THIS EXISTS
//
// The PMT2100 SDK ships a plain C DLL.  MATLAB's usual way in, loadlibrary,
// has to parse the vendor header and build a 64-bit thunk, and both need a
// C compiler configured through mex -setup.  There is none on this machine,
// and the vendor header cannot be parsed by MATLAB anyway: it declares
// C++ reference parameters (long &DeviceCount), which loadlibrary does not
// understand.
//
// A .NET assembly sidesteps both problems.  MATLAB loads it with
// NET.addAssembly and calls it like any other class, and csc.exe ships with
// Windows, so building this needs nothing installed.  References become
// `out`/`ref` parameters here, which marshal to the same pointer the C++
// reference does.
//
// Build:
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:library
//       /out:ThorPmtShim.dll ThorPmtShim.cs
//
// The SDK DLL is stateful and single-session: FindDevices/SelectDevice pick
// the active device and every later call applies to it.  That is the
// vendor's design, not a limitation of this shim.

using System;
using System.Runtime.InteropServices;

namespace Thorlabs
{
    /// <summary>Parameter IDs from PMT2100_SDK.h, for the first PMT.</summary>
    public static class PmtParam
    {
        public const int DeviceType          = 0;
        public const int Pmt1GainPercent     = 700;
        public const int Pmt1Enable          = 701;
        public const int Pmt1Safety          = 713;   // read only, trip status
        public const int Pmt1BandwidthHz     = 722;
        public const int Pmt1GainVolts       = 750;   // read only
        public const int Pmt1OutputOffset    = 751;
        public const int Pmt1OutputOffsetNow = 752;   // read only
        public const int Pmt1SerialNumber    = 753;   // read only
        public const int ConnectedPmts       = 786;   // bitmask of present PMTs
        public const int Pmt1BandwidthNowHz  = 920;   // read only
    }

    public static class Pmt
    {
        const string Dll = "ThorPMT2100.dll";

        // The SDK is __cdecl and exports undecorated names.
        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int FindDevices(out int deviceCount);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int SelectDevice(int device);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int TeardownDevice();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int GetParamInfo(int paramID, out int paramType,
            out int paramAvailable, out int paramReadOnly,
            out double paramMin, out double paramMax, out double paramDefault);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int SetParam(int paramID, double param);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int GetParam(int paramID, out double param);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int PreflightPosition();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int SetupPosition();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int StartPosition();

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int StatusPosition(out int status);

        [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)]
        public static extern int PostflightPosition();

        /// <summary>
        /// Point the process at the folder holding ThorPMT2100.dll before
        /// the first P/Invoke, so the DLL and the settings XML beside it
        /// are found without copying anything or editing PATH globally.
        /// </summary>
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool SetDllDirectory(string lpPathName);

        public static bool SetSdkDirectory(string path)
        {
            return SetDllDirectory(path);
        }
    }
}
