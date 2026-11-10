import { query, mutation } from "./_generated/server";
import { getAuthUserId } from "@convex-dev/auth/server";
import { v } from "convex/values";
import { requireVerifiedBloom } from "./policy";
import type { QueryCtx } from "./_generated/server";
async function owner(ctx: QueryCtx) {
  const id = await getAuthUserId(ctx);
  if (!id) throw new Error("Sign in required");
  const email = requireVerifiedBloom(await ctx.db.get(id));
  return { id, email };
}
export const me = query({ args: {}, handler: async ctx => ({ email: (await owner(ctx)).email }) });
export const list = query({ args: {}, handler: async ctx => {
  const { id } = await owner(ctx);
  return await ctx.db.query("meetings").withIndex("by_owner_date", q => q.eq("ownerId", id)).order("desc").take(20);
}});
export const save = mutation({ args: { localId:v.string(), title:v.string(), transcript:v.string(), notes:v.string(), recordedAt:v.number(), revision:v.number() }, handler: async (ctx, args) => {
  const { id } = await owner(ctx);
  if (!/^[0-9a-f-]{36}$/i.test(args.localId) || args.title.length > 500 || args.transcript.length + args.notes.length > 400000 || !Number.isSafeInteger(args.revision) || args.revision < 0 || !Number.isFinite(args.recordedAt)) throw new Error("Invalid meeting");
  const old = await ctx.db.query("meetings").withIndex("by_owner_local", q => q.eq("ownerId", id).eq("localId", args.localId)).unique();
  if (old && old.revision > args.revision) throw new Error("A newer cloud copy exists; keep both copies before replacing it.");
  if (old && old.revision === args.revision) {
    if (old.transcript !== args.transcript || old.notes !== args.notes || old.title !== args.title) throw new Error("Cloud revision conflict");
    return { revision:old.revision };
  }
  const doc = { ...args, ownerId:id, updatedAt:Date.now() };
  if (old) await ctx.db.patch(old._id, doc); else await ctx.db.insert("meetings", doc);
  return { revision:args.revision };
}});
