const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Spinlock = struct {
    mtx: std.Thread.Mutex = .{},
    pub fn lock(self: *Spinlock) void {
        while (!self.mtx.tryLock()) {
            // std.Thread.yield() catch {};
        }
    }
    pub fn unlock(self: *Spinlock) void {
        self.mtx.unlock();
    }
    pub fn try_lock(self: *Spinlock) bool {
        return self.mtx.tryLock();
    }
};

pub fn SpscFifo(comptime T: type) type {
    return struct {
        const Self = @This();
        capacity: usize,
        back: usize = 0,
        cback: usize = 0,
        front: usize = 0,
        pfront: usize = 0,
        data: []T,
        pub fn init(alloc: Allocator, capacity: usize) !Self {
            const data = try alloc.alloc(T, capacity);
            return Self{
                .capacity = capacity,
                .data = data,
            };
        }
        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.data);
        }
        pub fn push_slice(self: *Self, items: []const T) !void {
            const n = items.len;
            const b = @atomicLoad(usize, &self.back, .unordered);
            if ((self.pfront + self.capacity - b) < n) {
                self.pfront = @atomicLoad(usize, &self.front, .acquire);
                if ((self.pfront + self.capacity - b) < n) {
                    return error.NotEnoughSpace;
                }
            }
            for (0..n) |i| {
                self.data[(b + i) % self.capacity] = items[i];
            }
            @atomicStore(usize, &self.back, b + n, .release);
        }
        pub fn pop_slice(self: *Self, items: []T) !void {
            const n = items.len;
            const f = @atomicLoad(usize, &self.front, .unordered);
            if ((self.cback - f) < n) {
                self.cback = @atomicLoad(usize, &self.back, .acquire);
                if ((self.cback - f) < n) {
                    return error.NotEnoughItems;
                }
            }
            for (items, 0..) |*e, i| {
                e.* = self.data[(f + i) % self.capacity];
            }
            @atomicStore(usize, &self.front, f + n, .release);
        }
        pub fn push(self: *Self, item: T) !void {
            const xitem: [1]T = .{item};
            try self.push_slice(&xitem);
        }
        pub fn pop(self: *Self) ?T {
            var empty: [1]T = undefined;
            self.pop_slice(&empty) catch {
                return null;
            };
            return empty[0];
        }
    };
}
pub fn SpinLockMPSC(comptime T: type) type {
    return struct {
        fifo: SpscFifo(T),
        writer_lock: Spinlock = .{},
        pub fn init(alloc: Allocator, capacity: usize) !@This() {
            return @This(){
                .fifo = try SpscFifo(T).init(alloc, capacity),
            };
        }
        pub fn deinit(self: *@This(), alloc: Allocator) void {
            self.fifo.deinit(alloc);
        }
        pub fn push(self: *@This(), item: T) !void {
            self.writer_lock.lock();
            defer self.writer_lock.unlock();
            try self.fifo.push(item);
        }
        pub fn pop(self: *@This()) ?T {
            return self.fifo.pop();
        }
    };
}

pub fn AcqRelAtomic(T: type) type {
    return struct {
        raw: std.atomic.Value(T),
        pub fn init(val: T) @This() {
            return @This(){
                .raw = std.atomic.Value(T).init(val),
            };
        }
        pub fn load(self: *const @This()) T {
            return self.raw.load(.acquire);
        }
        pub fn store(self: *@This(), val: T) void {
            self.raw.store(val, .release);
        }
    };
}
