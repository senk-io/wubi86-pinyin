//go:build !darwin && !windows

package main

func probeHW() hwInfo { return hwInfo{} }
