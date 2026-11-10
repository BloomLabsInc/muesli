import { expect, test } from "vitest";
import { convexTest } from "convex-test";
import schema from "../convex/schema";
import { api } from "../convex/_generated/api";
import { bloomEmail, requireVerifiedBloom } from "../convex/policy";
const modules = import.meta.glob("../convex/**/*.ts");
test("email allowlist rejects suffix attacks and unverified identities", () => {
 for (const email of ["david@gmail.com", "x@bloom.diy.evil.com", "x@evilbloom.diy", "@bloom.diy", "a\nb@bloom.diy"]) expect(()=>bloomEmail(email)).toThrow();
 expect(bloomEmail("David@bloom.diy")).toBe("david@bloom.diy");
 expect(()=>requireVerifiedBloom({email:"david@bloom.diy"})).toThrow();
});
test("private meetings, anonymous denial, retry deduplication and stale-write protection", async () => {
 const t=convexTest(schema, modules);
 const a=await t.run(ctx=>ctx.db.insert("users",{email:"a@bloom.diy",emailVerificationTime:1}));
 const b=await t.run(ctx=>ctx.db.insert("users",{email:"b@bloom.diy",emailVerificationTime:1}));
 const outsider=await t.run(ctx=>ctx.db.insert("users",{email:"x@example.com",emailVerificationTime:1}));
 const unverified=await t.run(ctx=>ctx.db.insert("users",{email:"x@bloom.diy"}));
 const ca=t.withIdentity({subject:`${a}|session`}), cb=t.withIdentity({subject:`${b}|session`});
 const doc={localId:"12345678-1234-1234-1234-123456789abc",title:"Synthetic",transcript:"Private to A",notes:"",recordedAt:1,revision:2};
 await expect(t.mutation(api.meetings.save,doc)).rejects.toThrow();
 await expect(t.withIdentity({subject:`${outsider}|session`}).mutation(api.meetings.save,doc)).rejects.toThrow();
 await expect(t.withIdentity({subject:`${unverified}|session`}).query(api.meetings.list,{})).rejects.toThrow();
 await ca.mutation(api.meetings.save,doc); await ca.mutation(api.meetings.save,doc);
 await expect(ca.mutation(api.meetings.save,{...doc,transcript:"stale",revision:1})).rejects.toThrow();
 await expect(ca.mutation(api.meetings.save,{...doc,transcript:"conflict"})).rejects.toThrow();
 expect(await cb.query(api.meetings.list,{})).toEqual([]);
 const rows=await ca.query(api.meetings.list,{}); expect(rows).toHaveLength(1); expect(rows[0].transcript).toBe("Private to A");
});
