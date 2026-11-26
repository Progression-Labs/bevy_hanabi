// An effect's update kernel: a thread per slot. A live particle ages, runs the update modifiers
// and, still alive, the render modifiers, which shape its TLAS instance row (its axes scaled by
// its size, at its position) and colour its tint.
//
// A slot that has held a particle parks its row once the particle dies: a sphere a millionth of
// the particle mesh's size at the emitter, which nothing sees, but which stays in aurora's TLAS
// build (instances.slang `slotLive` leaves out only rows with no axes). A Vulkan TLAS update may
// not turn an instance on or off, so with every dead particle's row emptied each death and birth
// changed the build's instances and aurora rebuilt the TLAS every frame an effect ran (zero
// #1028). The slots are a stack (each death pushes its slot back on top, each birth takes the
// top), so the slots ever used are the most ever alive at once: a slot never used keeps an empty
// row, and an effect costs the build its peak of particles, not its capacity.

// Where a dead particle's row waits: the emitter, in the world, with axes of a millionth (not
// zero: a singular transform is no instance's).
Transform parked_row() {
    let s = 1.0e-6;
    return { float4(s, 0.0, 0.0, spawner.transform[0].w), float4(0.0, s, 0.0, spawner.transform[1].w),
             float4(0.0, 0.0, s, spawner.transform[2].w) };
}

{{UPDATE_EXTRA}}

{{RENDER_EXTRA}}

[shader("compute")]
[numthreads(64, 1, 1)]
void update(uint3 gid: SV_DispatchThreadID) {
    load_frame();
    let slot = gid.x;
    if (slot >= spawner.capacity) {
        return;
    }
    let state = push.alive[slot];
    if (state == 0u) {
        writeRow(push.rows, slot, noTransform(), noTransform());
        return;
    }
    if (state == 3u) {
        writeRow(push.rows, slot, parked_row(), parked_row());
        return;
    }

    seed = pcg_hash(slot ^ spawner.seed);
    var particle = push.particles[slot];
    {{AGE_CODE}}
    {{REAP_CODE}}
    {{UPDATE_CODE}}

    if (!is_alive) {
        push.alive[slot] = 3u;
        int at;
        InterlockedAdd(push.state.free_count, 1, at);
        push.free_slots[at] = slot;
        InterlockedAdd(push.state.alive_count, 0xFFFFFFFFu);
        writeRow(push.rows, slot, parked_row(), parked_row());
        return;
    }
{{WRITEBACK_CODE}}

{{INPUTS}}
{{VERTEX_MODIFIERS}}

    // Simulation space to world: the emitter's transform (local simulation) or none.
#if LOCAL_SPACE_SIMULATION
    let e = emitter_transform();
#else
    let e = float4x4(1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0);
#endif
    let s = float4x4(float4(axis_x.x * size.x, axis_y.x * size.y, axis_z.x * size.z, position.x),
                     float4(axis_x.y * size.x, axis_y.y * size.y, axis_z.y * size.z, position.y),
                     float4(axis_x.z * size.x, axis_y.z * size.y, axis_z.z * size.z, position.z),
                     float4(0.0, 0.0, 0.0, 1.0));
    let w = mul(e, s);
    Transform now = { w[0], w[1], w[2] };
    let prev = state == 2u ? now : push.last[slot];
    push.last[slot] = now;
    push.alive[slot] = 1u;
    writeRow(push.rows, slot, now, prev);
    // Its colour: what the effect's material takes when it has `instance_tint`.
    writeTint(push.rows, slot, color);
}
