//go:build !darwin && !windows

package main

func probeHW() hwInfo { return hwInfo{} }

func probeMemoryTight() bool { return false }
