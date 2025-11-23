[?1049h[22;0;0t[24;1H[?1h=package main

import (
        "bufio"
        "bytes"
        "fmt"
        "math"
        "os"
        "os/exec"
        "strings"
)

func main() {
        if len(os.Args) < 2 {
                fmt.Println("usage: go run verifierA.go /path/to/binary")
                os.Exit(1)
        }
        binary := os.Args[1]
        file, err := os.Open("testcasesA.txt")
        if err != nil {
                panic(err)
        }
        defer file.Close()
pod "psql-client3" deleted
