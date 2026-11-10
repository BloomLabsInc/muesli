import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";
import { authTables } from "@convex-dev/auth/server";
export default defineSchema({
  ...authTables,
  meetings: defineTable({ ownerId: v.id("users"), localId: v.string(), title: v.string(), transcript: v.string(), notes: v.string(), recordedAt: v.number(), revision: v.number(), updatedAt: v.number() }).index("by_owner_local", ["ownerId", "localId"]).index("by_owner_date", ["ownerId", "recordedAt"]),
});
