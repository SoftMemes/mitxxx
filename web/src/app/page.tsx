import LoginForm from "@/components/LoginForm";

export default function Home() {
  return (
    <main className="flex flex-col items-center justify-center min-h-screen p-8">
      <div className="w-full max-w-sm space-y-8">
        <div className="text-center">
          <div className="inline-block bg-[#8a1c1c] text-white text-xl font-bold px-4 py-2 rounded mb-4">
            MITx
          </div>
          <h1 className="text-2xl font-bold">Sign in</h1>
          <p className="text-sm text-gray-500 mt-1">
            Unofficial offline course browser
          </p>
        </div>
        <LoginForm />
        <p className="text-center text-xs text-gray-400">
          This is an unofficial app, not affiliated with MIT or MITx.
        </p>
      </div>
    </main>
  );
}
