--[[
    FName constructor, found by its prologue rather than by a fixed address.

    Replaces:
        local ImageBase = MatchAddress - 0x238D414
        return ImageBase + 0x3C7DB26

    which is valid for one build only. See GMalloc.lua for why that fails
    dangerously rather than cleanly.

    The pattern is the function's own prologue:

        41 56              push r14
        56                 push rsi
        57                 push rdi
        53                 push rbx
        48 81 EC 48 04 00 00   sub rsp, 0x448
        44 89 C3           mov ebx, r8d
        48                 (start of the mov that follows)

    The 0x448 stack allocation is part of the pattern and is a strong
    discriminator. It would change if the function's locals change, which is the
    tradeoff for not depending on an address.

    Matches exactly once in the verified build, at RVA 0x3C7DB26, which is the
    hardcoded value it replaces.

    Verified against SWGR-Win64-Shipping.exe
    sha256 825d4e6e639b541abbc008f728d2ad16422bb74bdcf6b4844f60bcfaac502d7e

    If a patch breaks this, re-derive with tools/derive-signatures.py.
--]]

function Register()
    return "41 56 56 57 53 48 81 EC 48 04 00 00 44 89 C3 48"
end

function OnMatchFound(MatchAddress)
    -- The pattern starts at the first byte of the function.
    return MatchAddress
end
