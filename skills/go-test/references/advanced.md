# 高级测试模式 - 完整代码

基线：go1.24.6，testify v1.12.1。

## Golden Files（黄金文件）

适合复杂输出（HTML、JSON）的测试。

```go
import (
    "bytes"
    "flag"
    "os"
    "path/filepath"
    "testing"

    "github.com/stretchr/testify/require"
)

var update = flag.Bool("update", false, "update golden files")

func TestRender(t *testing.T) {
    got := Render(input)
    golden := filepath.Join("testdata", t.Name()+".golden")

    if *update {
        require.NoError(t, os.WriteFile(golden, got, 0o644))
        return
    }

    want, err := os.ReadFile(golden)
    require.NoError(t, err)

    if !bytes.Equal(got, want) {
        t.Errorf("output mismatch, run with -update to update golden file")
    }
}
```

**更新**：`go test -update ./...`

## 子进程测试（exec.Command）

测试调用外部命令的代码。

```go
import (
    "fmt"
    "os"
    "os/exec"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestCommand(t *testing.T) {
    if os.Getenv("GO_WANT_HELPER_PROCESS") == "1" {
        // 这是子进程，模拟命令输出
        fmt.Println("mocked output")
        os.Exit(0)
    }

    // 主测试进程
    cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestCommand$")
    cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")

    output, err := cmd.Output()
    require.NoError(t, err)
    assert.Contains(t, string(output), "mocked output")
}
```

## 测试 Helper

```go
import (
    "database/sql"
    "testing"

    "github.com/stretchr/testify/require"
    // 驱动按项目选择并以空白导入注册，例如 _ "modernc.org/sqlite"（纯 Go，驱动名 "sqlite"）
)

func setupTestDB(t *testing.T) *sql.DB {
    t.Helper() // 错误报告在调用处

    db, err := sql.Open("sqlite", ":memory:")
    require.NoError(t, err)

    t.Cleanup(func() {
        _ = db.Close()
    })

    return db
}
```

