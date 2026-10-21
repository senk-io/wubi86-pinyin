package main

import (
	"runtime"
	"sync"
	"time"
)

// 后台抽取术语的自动限速：根据机器情况决定占用模型的时间比例（见 Config.IndexDuty）。
//   - Apple 芯片的 Mac 由 GPU 跑模型，起点 0.5；其它机器（Intel Mac、Windows）多半靠 CPU，起点 0.25
//   - 内存少于 16GB：减半（7B 模型本身要占约 5GB）
//   - 正在用电池：减半
// 电源状态每分钟最多查一次。

type hwInfo struct {
	memBytes  uint64 // 0 表示未知
	onBattery bool
}

var (
	hwMu      sync.Mutex
	hwCached  hwInfo
	hwChecked time.Time
)

func currentHW() hwInfo {
	hwMu.Lock()
	defer hwMu.Unlock()
	if time.Since(hwChecked) >= time.Minute {
		hwCached = probeHW()
		hwChecked = time.Now()
	}
	return hwCached
}

// autoDuty 由机器情况算出占用比例。
func autoDuty(goos, goarch string, hw hwInfo) float64 {
	duty := 0.25
	if goos == "darwin" && goarch == "arm64" {
		duty = 0.5
	}
	if hw.memBytes > 0 && hw.memBytes < 16<<30 {
		duty /= 2
	}
	if hw.onBattery {
		duty /= 2
	}
	return duty
}

// indexDuty 返回本次应使用的占用比例：配置为 0（默认）时自动决定，否则用配置值。
func (c Config) indexDuty() float64 {
	if c.IndexDuty > 0 {
		return c.IndexDuty
	}
	return autoDuty(runtime.GOOS, runtime.GOARCH, currentHW())
}
