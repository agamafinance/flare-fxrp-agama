'use client';

import { FlareNav } from './FlareNav';

// Green outer + a cream rounded panel that scrolls, mirroring the app.agama.finance frame.
export function AppFrame({ children }: { children: React.ReactNode }) {
  return (
    <div className="h-screen flex flex-col">
      <FlareNav />
      <div className="frame-panel md:rounded-[20px] flex-1 md:mx-[10.5px] md:mb-[10.5px] overflow-hidden">
        <div className="h-full overflow-y-auto overflow-x-hidden no-scrollbar">
          <main>{children}</main>
        </div>
      </div>
    </div>
  );
}
