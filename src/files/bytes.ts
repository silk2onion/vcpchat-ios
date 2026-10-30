export function bytesFromDataUrl(value: string): Uint8Array { const match=/^data:[^;,]+;base64,([a-z0-9+/=\s]+)$/i.exec(value);if(!match)throw new Error("文件数据格式无效");const data=atob(match[1]);return Uint8Array.from(data,(v)=>v.charCodeAt(0)); }
export function base64(bytes:Uint8Array):string{let value="";for(let i=0;i<bytes.length;i+=8192)value+=String.fromCharCode(...bytes.subarray(i,i+8192));return btoa(value);}
export function dataUrlFromBytes(bytes:Uint8Array):string{
  let mime="";if(bytes[0]===137&&bytes[1]===80&&bytes[2]===78)mime="image/png";else if(bytes[0]===255&&bytes[1]===216)mime="image/jpeg";else if(String.fromCharCode(...bytes.slice(0,3))==="GIF")mime="image/gif";else if(String.fromCharCode(...bytes.slice(0,4))==="RIFF"&&String.fromCharCode(...bytes.slice(8,12))==="WEBP")mime="image/webp";
  if(!mime)throw new Error("同步头像不是支持的 JPG、PNG、GIF 或 WebP 图片");return `data:${mime};base64,${base64(bytes)}`;
}
