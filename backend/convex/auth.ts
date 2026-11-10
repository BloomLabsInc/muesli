import { convexAuth } from "@convex-dev/auth/server";
import { Email } from "@convex-dev/auth/providers/Email";
import { bloomEmail, requireVerifiedBloom } from "./policy";
export const { auth, signIn, signOut, store, isAuthenticated } = convexAuth({
  providers: [
    Email({
      id: "bloom-email",
      maxAge: 10 * 60,
      async generateVerificationToken() {
        const bytes = new Uint8Array(8);
        crypto.getRandomValues(bytes);
        return Array.from(bytes, (x) => x.toString(16).padStart(2, "0")).join(
          "",
        );
      },
      async sendVerificationRequest({ identifier, token }) {
        const email = bloomEmail(identifier);
        const result = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${process.env.AUTH_RESEND_KEY}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: "Bloom Meetings <auth@bloom.diy>",
            to: [email],
            subject: "Your Bloom Meetings sign-in code",
            text: `Your Bloom Meetings code is:\n\n${token}\n\nIt expires in 10 minutes. If you did not request this, ignore this email.`,
          }),
        });
        if (!result.ok)
          throw new Error(`Sign-in email could not be sent (${result.status})`);
      },
    }),
  ],
  callbacks: {
    beforeSessionCreation: async (ctx, { userId }) => {
      requireVerifiedBloom(await ctx.db.get(userId));
    },
  },
});
