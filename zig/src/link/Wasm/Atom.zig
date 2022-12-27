const Atom = @This();

const std = @import("std");
const types = @import("types.zig");
const Wasm = @import("../Wasm.zig");
const Symbol = @import("Symbol.zig");
const Dwarf = @import("../Dwarf.zig");

const leb = std.leb;
const log = std.log.scoped(.link);
const mem = std.mem;
const Allocator = mem.Allocator;

/// symbol index of the symbol representing this atom
sym_index: u32,
/// Size of the atom, used to calculate section sizes in the final binary
size: u32,
/// List of relocations belonging to this atom
relocs: std.ArrayListUnmanaged(types.Relocation) = .{},
/// Contains the binary data of an atom, which can be non-relocated
code: std.ArrayListUnmanaged(u8) = .{},
/// For code this is 1, for data this is set to the highest value of all segments
alignment: u32,
/// Offset into the section where the atom lives, this already accounts
/// for alignment.
offset: u32,
/// Represents the index of the file this atom was generated from.
/// This is 'null' when the atom was generated by a Decl from Zig code.
file: ?u16,

/// Next atom in relation to this atom.
/// When null, this atom is the last atom
next: ?*Atom,
/// Previous atom in relation to this atom.
/// is null when this atom is the first in its order
prev: ?*Atom,

/// Contains atoms local to a decl, all managed by this `Atom`.
/// When the parent atom is being freed, it will also do so for all local atoms.
locals: std.ArrayListUnmanaged(Atom) = .{},

/// Represents the debug Atom that holds all debug information of this Atom.
dbg_info_atom: Dwarf.Atom,

/// Represents a default empty wasm `Atom`
pub const empty: Atom = .{
    .alignment = 0,
    .file = null,
    .next = null,
    .offset = 0,
    .prev = null,
    .size = 0,
    .sym_index = 0,
    .dbg_info_atom = undefined,
};

/// Frees all resources owned by this `Atom`.
pub fn deinit(atom: *Atom, gpa: Allocator) void {
    atom.relocs.deinit(gpa);
    atom.code.deinit(gpa);

    for (atom.locals.items) |*local| {
        local.deinit(gpa);
    }
    atom.locals.deinit(gpa);
}

/// Sets the length of relocations and code to '0',
/// effectively resetting them and allowing them to be re-populated.
pub fn clear(atom: *Atom) void {
    atom.relocs.clearRetainingCapacity();
    atom.code.clearRetainingCapacity();
}

pub fn format(atom: Atom, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
    _ = fmt;
    _ = options;
    try writer.print("Atom{{ .sym_index = {d}, .alignment = {d}, .size = {d}, .offset = 0x{x:0>8} }}", .{
        atom.sym_index,
        atom.alignment,
        atom.size,
        atom.offset,
    });
}

/// Returns the first `Atom` from a given atom
pub fn getFirst(atom: *Atom) *Atom {
    var tmp = atom;
    while (tmp.prev) |prev| tmp = prev;
    return tmp;
}

/// Unlike `getFirst` this returns the first `*Atom` that was
/// produced from Zig code, rather than an object file.
/// This is useful for debug sections where we want to extend
/// the bytes, and don't want to overwrite existing Atoms.
pub fn getFirstZigAtom(atom: *Atom) *Atom {
    if (atom.file == null) return atom;
    var tmp = atom;
    return while (tmp.prev) |prev| {
        if (prev.file == null) break prev;
        tmp = prev;
    } else unreachable; // must allocate an Atom first!
}

/// Returns the location of the symbol that represents this `Atom`
pub fn symbolLoc(atom: Atom) Wasm.SymbolLoc {
    return .{ .file = atom.file, .index = atom.sym_index };
}

/// Resolves the relocations within the atom, writing the new value
/// at the calculated offset.
pub fn resolveRelocs(atom: *Atom, wasm_bin: *const Wasm) void {
    if (atom.relocs.items.len == 0) return;
    const symbol_name = atom.symbolLoc().getName(wasm_bin);
    log.debug("Resolving relocs in atom '{s}' count({d})", .{
        symbol_name,
        atom.relocs.items.len,
    });

    for (atom.relocs.items) |reloc| {
        const value = atom.relocationValue(reloc, wasm_bin);
        log.debug("Relocating '{s}' referenced in '{s}' offset=0x{x:0>8} value={d}", .{
            (Wasm.SymbolLoc{ .file = atom.file, .index = reloc.index }).getName(wasm_bin),
            symbol_name,
            reloc.offset,
            value,
        });

        switch (reloc.relocation_type) {
            .R_WASM_TABLE_INDEX_I32,
            .R_WASM_FUNCTION_OFFSET_I32,
            .R_WASM_GLOBAL_INDEX_I32,
            .R_WASM_MEMORY_ADDR_I32,
            .R_WASM_SECTION_OFFSET_I32,
            => std.mem.writeIntLittle(u32, atom.code.items[reloc.offset..][0..4], @intCast(u32, value)),
            .R_WASM_TABLE_INDEX_I64,
            .R_WASM_MEMORY_ADDR_I64,
            => std.mem.writeIntLittle(u64, atom.code.items[reloc.offset..][0..8], value),
            .R_WASM_GLOBAL_INDEX_LEB,
            .R_WASM_EVENT_INDEX_LEB,
            .R_WASM_FUNCTION_INDEX_LEB,
            .R_WASM_MEMORY_ADDR_LEB,
            .R_WASM_MEMORY_ADDR_SLEB,
            .R_WASM_TABLE_INDEX_SLEB,
            .R_WASM_TABLE_NUMBER_LEB,
            .R_WASM_TYPE_INDEX_LEB,
            => leb.writeUnsignedFixed(5, atom.code.items[reloc.offset..][0..5], @intCast(u32, value)),
            .R_WASM_MEMORY_ADDR_LEB64,
            .R_WASM_MEMORY_ADDR_SLEB64,
            .R_WASM_TABLE_INDEX_SLEB64,
            => leb.writeUnsignedFixed(10, atom.code.items[reloc.offset..][0..10], value),
        }
    }
}

/// From a given `relocation` will return the new value to be written.
/// All values will be represented as a `u64` as all values can fit within it.
/// The final value must be casted to the correct size.
fn relocationValue(atom: Atom, relocation: types.Relocation, wasm_bin: *const Wasm) u64 {
    const target_loc = (Wasm.SymbolLoc{ .file = atom.file, .index = relocation.index }).finalLoc(wasm_bin);
    const symbol = target_loc.getSymbol(wasm_bin).*;
    switch (relocation.relocation_type) {
        .R_WASM_FUNCTION_INDEX_LEB => return symbol.index,
        .R_WASM_TABLE_NUMBER_LEB => return symbol.index,
        .R_WASM_TABLE_INDEX_I32,
        .R_WASM_TABLE_INDEX_I64,
        .R_WASM_TABLE_INDEX_SLEB,
        .R_WASM_TABLE_INDEX_SLEB64,
        => return wasm_bin.function_table.get(target_loc) orelse 0,
        .R_WASM_TYPE_INDEX_LEB => {
            const file_index = atom.file orelse {
                return relocation.index;
            };

            const original_type = wasm_bin.objects.items[file_index].func_types[relocation.index];
            return wasm_bin.getTypeIndex(original_type).?;
        },
        .R_WASM_GLOBAL_INDEX_I32,
        .R_WASM_GLOBAL_INDEX_LEB,
        => return symbol.index,
        .R_WASM_MEMORY_ADDR_I32,
        .R_WASM_MEMORY_ADDR_I64,
        .R_WASM_MEMORY_ADDR_LEB,
        .R_WASM_MEMORY_ADDR_LEB64,
        .R_WASM_MEMORY_ADDR_SLEB,
        .R_WASM_MEMORY_ADDR_SLEB64,
        => {
            std.debug.assert(symbol.tag == .data);
            if (symbol.isUndefined()) {
                return 0;
            }

            const merge_segment = wasm_bin.base.options.output_mode != .Obj;
            const target_atom = wasm_bin.symbol_atom.get(target_loc).?;
            const segment_info = if (target_atom.file) |object_index| blk: {
                break :blk wasm_bin.objects.items[object_index].segment_info;
            } else wasm_bin.segment_info.values();
            const segment_name = segment_info[symbol.index].outputName(merge_segment);
            const segment_index = wasm_bin.data_segments.get(segment_name).?;
            const segment = wasm_bin.segments.items[segment_index];
            const rel_value = @intCast(i32, target_atom.offset + segment.offset) + relocation.addend;
            return @intCast(u32, rel_value);
        },
        .R_WASM_EVENT_INDEX_LEB => return symbol.index,
        .R_WASM_SECTION_OFFSET_I32 => {
            const target_atom = wasm_bin.symbol_atom.get(target_loc).?;
            const rel_value = @intCast(i32, target_atom.offset) + relocation.addend;
            return @intCast(u32, rel_value);
        },
        .R_WASM_FUNCTION_OFFSET_I32 => {
            const target_atom = wasm_bin.symbol_atom.get(target_loc) orelse {
                return @bitCast(u32, @as(i32, -1));
            };
            const offset: u32 = 11 + Wasm.getULEB128Size(target_atom.size); // Header (11 bytes fixed-size) + body size (leb-encoded)
            const rel_value = @intCast(i32, target_atom.offset + offset) + relocation.addend;
            return @intCast(u32, rel_value);
        },
    }
}
