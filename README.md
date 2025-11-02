# novin.cloud-benchtool
Simple benchmark tool to test our servers.

## Usage:
1- Create a simple ubuntu server on the zone you want to test.  
2- Get the script: `wget https://raw.githubusercontent.com/novincloud/novin.cloud-benchtool/refs/heads/main/benchmark.sh`  
3- Run the script: `sudo bash benchmark.sh`

## More detail:
Faster run: `MEM_TOTAL=512M FILESIZE=1G DURATION=15 sudo -E bash benchmark.sh`  
Heavier run: `MEM_TOTAL=4G FILESIZE=8G DURATION=60 sudo -E bash benchmark.sh`  

## Sample output:
```
=================== Benchmark Summary ===================
CPU (single-core 'CPUMark', sysbench events/sec):  311.98
Memory throughput (MiB/s):                         11752.24
Disk throughput (MiB/s):
  - Sequential Write:                              70.58
  - Sequential Read:                               137.11
  - Random Write (4k):                             1.14
  - Random Read  (4k):                             3.07
Network:
  - Download (Mb/s):                               613.01
  - Upload   (Mb/s):                               1007.59
  - Ping (ms):                                     19.28
=========================================================

{
  "cpu_single_events_per_sec": "311.98",
  "memory_mib_per_sec": "11752.24",
  "disk": {
    "sequential_write_mib_per_sec": "70.58",
    "sequential_read_mib_per_sec": "137.11",
    "random_write_4k_mib_per_sec": "1.14",
    "random_read_4k_mib_per_sec": "3.07"
  },
  "network": {
    "download_Mbps": "613.01",
    "upload_Mbps": "1007.59",
    "ping_ms": "19.28"
  }
}

```  

novin.cloud
