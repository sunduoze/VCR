import sys
f = r'D:\AI\upper_computer_tools\VCR\rust\src\api\lua_api.rs'
with open(f, 'rb') as fp:
    raw = fp.read()
lf_count = raw.count(b'\n')
crlf_count = raw.count(b'\r\n')
print(f'LF: {lf_count}, CRLF: {crlf_count}')
print('Line 60:', raw[0:100])