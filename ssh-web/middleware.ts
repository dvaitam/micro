import { NextResponse } from 'next/server'

export function middleware(req: Request) {
  const url = new URL(req.url)
  if (url.pathname === '/favicon.ico') {
    return new NextResponse('', { status: 204, headers: { 'Content-Type': 'image/x-icon' } })
  }
  return NextResponse.next()
}

export const config = {
  matcher: ['/favicon.ico'],
}

