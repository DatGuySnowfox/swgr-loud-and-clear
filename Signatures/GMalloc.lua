--[[
    GMalloc, found by content rather than by a fixed address.

    Replaces a version of this file that did:

        local ImageBase = MatchAddress - 0x238D414
        return ImageBase + 0xAB747C8

    which derives the image base from one anchor and then jumps to a hardcoded
    absolute RVA. That is valid for exactly one build. The anchor it used is a
    distinctive sequence occurring exactly once, so after a game patch it will
    very likely still match, UE4SS will report a successful scan, and the engine
    will be handed a wrong pointer. Crashing, rather than failing cleanly.

    The pattern below is FMemory::Malloc's dispatch through the allocator vtable:

        48 8B 0D ? ? ? ?   mov rcx, [GMalloc]
        48 85 C9           test rcx, rcx
        74 0A              jz   lazy_init
        48 8B 01           mov  rax, [rcx]
        48 8B 40 28        mov  rax, [rax+0x28]
        48 FF E0           jmp  rax

    The displacement is wildcarded and resolved at runtime, so the pattern does
    not care where the code sits.

    Matches three times in the verified build, at RVAs 0x1BFC, 0x123A784 and
    0x4D30F8A, and all three resolve to the same address. UE4SS dedupes by
    resolved value, not by match count, so that is accepted. It is also a
    durability win: two of the three sites can disappear and this still works.

    Verified against SWGR-Win64-Shipping.exe
    sha256 825d4e6e639b541abbc008f728d2ad16422bb74bdcf6b4844f60bcfaac502d7e
    Resolves to 0xAB747C8, matching the hardcoded value it replaces.

    If a patch breaks this, re-derive with tools/derive-signatures.py.
--]]

function Register()
    return "48 8B 0D ? ? ? ? 48 85 C9 74 0A 48 8B 01 48 8B 40 28 48 FF E0"
end

function OnMatchFound(MatchAddress)
    -- Standard rip-relative resolve: the displacement is relative to the end of
    -- the 7-byte instruction, so read it and add it to the next instruction.
    local InstructionLength = 7
    local DisplacementAt = MatchAddress + 3
    return MatchAddress + InstructionLength + DerefToInt32(DisplacementAt)
end
