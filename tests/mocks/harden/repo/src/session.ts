export function setCookie(headers: Headers, id: string): void {
  headers.append("Set-Cookie", `sid=${id}; Path=/; Secure`);
}
