# Adds / removes ONE Windows user right for ONE account (dot-sourced by install.ps1 and uninstall.ps1).
# Used only for "Log on as a batch job" (SeBatchLogonRight), which a scheduled task needs to run
# as the non-admin inventory_sync account. Nothing else in the security policy is touched.
if (-not ('InvSyncUserRights' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

public static class InvSyncUserRights {
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }

    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public int Length; public IntPtr RootDirectory; public IntPtr ObjectName;
        public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
    }

    [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaRemoveAccountRights(IntPtr handle, byte[] sid, bool allRights, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);

    const uint POLICY_CREATE_ACCOUNT = 0x00000010;
    const uint POLICY_LOOKUP_NAMES = 0x00000800;
    const uint STATUS_OBJECT_NAME_NOT_FOUND = 0xC0000034;

    static void Change(string sidText, string right, bool add) {
        var sid = new SecurityIdentifier(sidText);
        var sidBytes = new byte[sid.BinaryLength];
        sid.GetBinaryForm(sidBytes, 0);

        var attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy;
        uint status = LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES, out policy);
        if (status != 0) throw new Win32Exception(LsaNtStatusToWinError(status));
        try {
            var name = new LSA_UNICODE_STRING();
            name.Buffer = Marshal.StringToHGlobalUni(right);
            name.Length = (ushort)(right.Length * 2);
            name.MaximumLength = (ushort)(right.Length * 2 + 2);
            try {
                status = add
                    ? LsaAddAccountRights(policy, sidBytes, new[] { name }, 1)
                    : LsaRemoveAccountRights(policy, sidBytes, false, new[] { name }, 1);
                if (status != 0 && !(!add && status == STATUS_OBJECT_NAME_NOT_FOUND))
                    throw new Win32Exception(LsaNtStatusToWinError(status));
            } finally { Marshal.FreeHGlobal(name.Buffer); }
        } finally { LsaClose(policy); }
    }

    public static void Grant(string sid, string right) { Change(sid, right, true); }
    public static void Revoke(string sid, string right) { Change(sid, right, false); }
}
'@
}
