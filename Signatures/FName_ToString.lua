--[[
    FName::ToString, found by its prologue rather than by a fixed address.

    Replaces:
        local ImageBase = MatchAddress - 0x238D414
        return ImageBase + 0x3752404

    which is valid for one build only. See GMalloc.lua for why that fails
    dangerously rather than cleanly.

    The pattern is the function's own prologue:

        41 57        push r15
        41 56        push r14
        56           push rsi
        57           push rdi
        55           push rbp
        53           push rbx
        48 83 EC 38  sub  rsp, 0x38
        48 89 D6     mov  rsi, rdx
        83           (start of the cmp that follows)

    No operands are wildcarded because none of these encode an address, so the
    pattern is position independent as written.

    Matches exactly once in the verified build, at RVA 0x3752404, which is the
    hardcoded value it replaces.

    Verified against SWGR-Win64-Shipping.exe
    sha256 825d4e6e639b541abbc008f728d2ad16422bb74bdcf6b4844f60bcfaac502d7e

    If a patch breaks this, re-derive with tools/derive-signatures.py.
--]]

function Register()
    return "41 57 41 56 56 57 55 53 48 83 EC 38 48 89 D6 83"
end

function OnMatchFound(MatchAddress)
    -- The pattern starts at the first byte of the function.
    return MatchAddress
end
