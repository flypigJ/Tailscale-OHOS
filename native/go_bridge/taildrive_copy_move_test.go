package main

import (
	"bytes"
	"context"
	"encoding/json"
	"encoding/xml"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

type fakeWebDAVNode struct {
	isDir                 bool
	body                  []byte
	chunked               bool
	overrideContentLength *int64
	modifiedAt            time.Time
}

type fakeWebDAVServer struct {
	mu              sync.Mutex
	nodes           map[string]*fakeWebDAVNode
	log             []string
	onPutBeforeRead func(*http.Request)
}

func newFakeWebDAVServer() *fakeWebDAVServer {
	return &fakeWebDAVServer{
		nodes: map[string]*fakeWebDAVNode{
			"/": {isDir: true, modifiedAt: time.Unix(1700000000, 0).UTC()},
		},
	}
}

func (s *fakeWebDAVServer) ensureDir(p string) {
	parts := strings.Split(strings.Trim(p, "/"), "/")
	cur := ""
	for _, part := range parts {
		if part == "" {
			continue
		}
		cur += "/" + part
		if _, ok := s.nodes[cur]; !ok {
			s.nodes[cur] = &fakeWebDAVNode{isDir: true, modifiedAt: time.Unix(1700000000, 0).UTC()}
		}
	}
}

func (s *fakeWebDAVServer) putFile(p string, content []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureDir(path.Dir(p))
	copied := append([]byte(nil), content...)
	s.nodes[p] = &fakeWebDAVNode{
		isDir:      false,
		body:       copied,
		modifiedAt: time.Unix(1700000100, 0).UTC(),
	}
}

func (s *fakeWebDAVServer) RoundTrip(req *http.Request) (*http.Response, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	p := req.URL.Path
	if p == "" {
		p = "/"
	}
	s.log = append(s.log, req.Method+" "+p)

	resp := &http.Response{
		Header: make(http.Header),
		Body:   http.NoBody,
	}

	switch req.Method {
	case "PROPFIND":
		node, ok := s.nodes[p]
		if !ok {
			resp.StatusCode = http.StatusNotFound
			return resp, nil
		}
		depth := req.Header.Get("Depth")
		if depth == "" {
			depth = "0"
		}
		type prop struct {
			ResourceType struct {
				Collection *struct{} `xml:"collection,omitempty"`
			} `xml:"resourcetype"`
			ContentLength string `xml:"getcontentlength,omitempty"`
			LastModified  string `xml:"getlastmodified,omitempty"`
		}
		type propstat struct {
			Prop   prop   `xml:"prop"`
			Status string `xml:"status"`
		}
		type davResp struct {
			Href     string   `xml:"href"`
			Propstat propstat `xml:"propstat"`
		}
		type multistatus struct {
			XMLName  xml.Name  `xml:"multistatus"`
			Xmlns    string    `xml:"xmlns,attr"`
			Response []davResp `xml:"response"`
		}

		makeResp := func(nodePath string, n *fakeWebDAVNode) davResp {
			var pr prop
			if n.isDir {
				pr.ResourceType.Collection = &struct{}{}
			} else if !n.chunked {
				pr.ContentLength = strconv.Itoa(len(n.body))
			}
			pr.LastModified = n.modifiedAt.UTC().Format(http.TimeFormat)
			encoded := (&url.URL{Path: nodePath}).EscapedPath()
			return davResp{
				Href: encoded,
				Propstat: propstat{
					Prop:   pr,
					Status: "HTTP/1.1 200 OK",
				},
			}
		}

		out := multistatus{Xmlns: "DAV:"}
		out.Response = append(out.Response, makeResp(p, node))
		if depth == "1" && node.isDir {
			prefix := p
			if prefix != "/" {
				prefix += "/"
			}
			var children []string
			for k := range s.nodes {
				if k == p || !strings.HasPrefix(k, prefix) {
					continue
				}
				rem := strings.TrimPrefix(k, prefix)
				if !strings.Contains(rem, "/") {
					children = append(children, k)
				}
			}
			sort.Strings(children)
			for _, c := range children {
				out.Response = append(out.Response, makeResp(c, s.nodes[c]))
			}
		}
		encoded, err := xml.Marshal(out)
		if err != nil {
			return nil, err
		}
		resp.StatusCode = http.StatusMultiStatus
		resp.Body = io.NopCloser(bytes.NewReader(encoded))
		return resp, nil

	case "MKCOL":
		if _, exists := s.nodes[p]; exists {
			resp.StatusCode = http.StatusMethodNotAllowed
			return resp, nil
		}
		parent := path.Dir(p)
		if pNode, ok := s.nodes[parent]; !ok || !pNode.isDir {
			resp.StatusCode = http.StatusConflict
			return resp, nil
		}
		s.nodes[p] = &fakeWebDAVNode{isDir: true, modifiedAt: time.Now().UTC()}
		resp.StatusCode = http.StatusCreated
		return resp, nil

	case http.MethodGet:
		node, ok := s.nodes[p]
		if !ok || node.isDir {
			resp.StatusCode = http.StatusNotFound
			return resp, nil
		}
		resp.StatusCode = http.StatusOK
		switch {
		case node.chunked:
			resp.ContentLength = -1
		case node.overrideContentLength != nil:
			resp.ContentLength = *node.overrideContentLength
		default:
			resp.ContentLength = int64(len(node.body))
		}
		resp.Body = io.NopCloser(bytes.NewReader(append([]byte(nil), node.body...)))
		return resp, nil

	case http.MethodPut:
		if req.Header.Get("If-None-Match") == "*" {
			if _, exists := s.nodes[p]; exists {
				resp.StatusCode = http.StatusPreconditionFailed
				return resp, nil
			}
		}
		parent := path.Dir(p)
		if pNode, ok := s.nodes[parent]; !ok || !pNode.isDir {
			resp.StatusCode = http.StatusConflict
			return resp, nil
		}
		if s.onPutBeforeRead != nil {
			s.onPutBeforeRead(req)
		}
		data, err := io.ReadAll(req.Body)
		if err != nil {
			return nil, err
		}
		s.nodes[p] = &fakeWebDAVNode{isDir: false, body: data, modifiedAt: time.Now().UTC()}
		resp.StatusCode = http.StatusCreated
		return resp, nil

	case http.MethodDelete:
		if _, exists := s.nodes[p]; !exists {
			resp.StatusCode = http.StatusNotFound
			return resp, nil
		}
		prefix := p + "/"
		for k := range s.nodes {
			if k == p || strings.HasPrefix(k, prefix) {
				delete(s.nodes, k)
			}
		}
		resp.StatusCode = http.StatusNoContent
		return resp, nil

	case "COPY", "MOVE":
		destURL, err := url.Parse(req.Header.Get("Destination"))
		if err != nil {
			resp.StatusCode = http.StatusBadRequest
			return resp, nil
		}
		dst := destURL.Path
		if !sameTaildriveShare(p, dst) {
			resp.StatusCode = http.StatusBadRequest
			resp.Body = io.NopCloser(strings.NewReader("Destination across shares is not supported"))
			return resp, nil
		}
		srcNode, ok := s.nodes[p]
		if !ok {
			resp.StatusCode = http.StatusNotFound
			return resp, nil
		}
		if req.Header.Get("Overwrite") != "T" {
			if _, exists := s.nodes[dst]; exists {
				resp.StatusCode = http.StatusPreconditionFailed
				return resp, nil
			}
		}
		parent := path.Dir(dst)
		if pNode, ok := s.nodes[parent]; !ok || !pNode.isDir {
			resp.StatusCode = http.StatusConflict
			return resp, nil
		}
		s.nodes[dst] = &fakeWebDAVNode{
			isDir:      srcNode.isDir,
			body:       append([]byte(nil), srcNode.body...),
			modifiedAt: srcNode.modifiedAt,
		}
		if req.Method == "MOVE" {
			delete(s.nodes, p)
		}
		resp.StatusCode = http.StatusCreated
		return resp, nil
	}

	resp.StatusCode = http.StatusMethodNotAllowed
	return resp, nil
}

func TestTaildriveSharePrefixAndComparison(t *testing.T) {
	for _, pathCase := range []string{"/", "/flypigj.github", "/flypigj.github/magicbookpro14"} {
		if prefix, ok := taildriveSharePrefix(pathCase); ok || prefix != "" {
			t.Fatalf("taildriveSharePrefix(%q) = (%q, %v); want empty/false", pathCase, prefix, ok)
		}
	}

	prefix, ok := taildriveSharePrefix("/FlypigJ.GitHub/MagicBookPro14/My%20Share/folder/file.txt")
	if !ok || prefix != "/flypigj.github/magicbookpro14/My Share" {
		t.Fatalf("taildriveSharePrefix got (%q, %v)", prefix, ok)
	}

	if !sameTaildriveShare("/flypigj.github/pc1/shareA/a.txt", "/FLYPIGJ.GITHUB/PC1/shareA/sub/b.txt") {
		t.Fatal("expected paths in the same share to match")
	}
	if sameTaildriveShare("/flypigj.github/pc1/shareA/a.txt", "/flypigj.github/pc1/shareB/a.txt") {
		t.Fatal("expected paths in different shares on same device not to match")
	}
	if sameTaildriveShare("/flypigj.github/pc1/shareA/a.txt", "/flypigj.github/pc2/shareA/a.txt") {
		t.Fatal("expected paths on different devices not to match")
	}
}

func TestTaildriveSameAndCrossShareCopyAndMove(t *testing.T) {
	srv := newFakeWebDAVServer()
	srv.mu.Lock()
	srv.ensureDir("/flypigj.github/pc1/shareA/sub")
	srv.ensureDir("/flypigj.github/pc1/shareB")
	srv.ensureDir("/flypigj.github/pc2/shareC")
	srv.mu.Unlock()

	srv.putFile("/flypigj.github/pc1/shareA/hello.txt", []byte("hello taildrive"))
	srv.putFile("/flypigj.github/pc1/shareA/empty.txt", nil)
	srv.putFile("/flypigj.github/pc1/shareA/sub/nested.bin", []byte{1, 2, 3, 4})

	client := &taildriveWebDAVClient{
		httpClient: &http.Client{Transport: srv},
	}
	ctx := context.Background()

	// 1. Same-share COPY stays single HTTP COPY.
	if err := client.mutate(ctx, taildriveMutationRequest{
		Operation: "copy",
		Path:      "/flypigj.github/pc1/shareA/hello.txt",
		NewPath:   "/flypigj.github/pc1/shareA/hello_same.txt",
	}); err != nil {
		t.Fatalf("same-share copy failed: %v", err)
	}
	if got := string(srv.nodes["/flypigj.github/pc1/shareA/hello_same.txt"].body); got != "hello taildrive" {
		t.Fatalf("same-share copied body = %q", got)
	}

	// 2. Cross-share empty file COPY across shares on same device streams GET -> PUT.
	if err := client.mutate(ctx, taildriveMutationRequest{
		Operation: "copy",
		Path:      "/flypigj.github/pc1/shareA/empty.txt",
		NewPath:   "/flypigj.github/pc1/shareB/empty_copy.txt",
	}); err != nil {
		t.Fatalf("cross-share empty file copy failed: %v", err)
	}
	emptyNode := srv.nodes["/flypigj.github/pc1/shareB/empty_copy.txt"]
	if emptyNode == nil || emptyNode.isDir || len(emptyNode.body) != 0 {
		t.Fatalf("cross-share empty file copy mismatch: %+v", emptyNode)
	}

	// 3. Cross-device recursive folder COPY preserves nested files and keeps source.
	if err := client.mutate(ctx, taildriveMutationRequest{
		Operation: "copy",
		Path:      "/flypigj.github/pc1/shareA/sub",
		NewPath:   "/flypigj.github/pc2/shareC/sub_copy",
	}); err != nil {
		t.Fatalf("cross-device dir copy failed: %v", err)
	}
	if got := srv.nodes["/flypigj.github/pc2/shareC/sub_copy/nested.bin"]; got == nil || !bytes.Equal(got.body, []byte{1, 2, 3, 4}) {
		t.Fatalf("cross-device nested file missing or mismatched: %+v", got)
	}
	if srv.nodes["/flypigj.github/pc1/shareA/sub/nested.bin"] == nil {
		t.Fatal("copy should preserve source file")
	}

	// 4. Overwrite: false fails with 412 (already_exists) without modifying destination or deleting source.
	err := client.mutate(ctx, taildriveMutationRequest{
		Operation: "move",
		Path:      "/flypigj.github/pc1/shareA/hello.txt",
		NewPath:   "/flypigj.github/pc1/shareB/empty_copy.txt",
		Overwrite: false,
	})
	var statusErr *taildriveHTTPStatusError
	if !errors.As(err, &statusErr) || statusErr.StatusCode != http.StatusPreconditionFailed {
		t.Fatalf("expected 412 precondition failed, got %v", err)
	}
	if srv.nodes["/flypigj.github/pc1/shareA/hello.txt"] == nil {
		t.Fatal("failed move must not delete source")
	}

	// 5. Cross-device folder MOVE transfers nested contents then deletes source.
	if err := client.mutate(ctx, taildriveMutationRequest{
		Operation: "move",
		Path:      "/flypigj.github/pc1/shareA/sub",
		NewPath:   "/flypigj.github/pc2/shareC/sub_moved",
	}); err != nil {
		t.Fatalf("cross-device folder move failed: %v", err)
	}
	if got := srv.nodes["/flypigj.github/pc2/shareC/sub_moved/nested.bin"]; got == nil || !bytes.Equal(got.body, []byte{1, 2, 3, 4}) {
		t.Fatalf("moved nested file missing: %+v", got)
	}
	if srv.nodes["/flypigj.github/pc1/shareA/sub"] != nil || srv.nodes["/flypigj.github/pc1/shareA/sub/nested.bin"] != nil {
		t.Fatal("cross-device folder move should delete source directory tree")
	}
}

func TestTaildriveUploadRejectsSymlinkDirectoryAndFifoAndBoundsConcurrentGrowth(t *testing.T) {
	tempDir := t.TempDir()
	stagingRoot := filepath.Join(tempDir, "staging")
	if err := os.MkdirAll(stagingRoot, 0o700); err != nil {
		t.Fatalf("mkdir staging: %v", err)
	}

	secretPath := filepath.Join(tempDir, "tailscaled.state")
	if err := os.WriteFile(secretPath, []byte("PRIVATE_NODE_KEY"), 0o600); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	symlinkPath := filepath.Join(stagingRoot, "symlink-escape.txt")
	if err := os.Symlink(secretPath, symlinkPath); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	subDirPath := filepath.Join(stagingRoot, "nested-dir")
	if err := os.MkdirAll(subDirPath, 0o700); err != nil {
		t.Fatalf("mkdir nested: %v", err)
	}

	fifoPath := filepath.Join(stagingRoot, "named-pipe.fifo")
	if err := unix.Mkfifo(fifoPath, 0o600); err != nil {
		t.Fatalf("mkfifo: %v", err)
	}

	srv := newFakeWebDAVServer()
	srv.mu.Lock()
	srv.ensureDir("/flypigj.github/pc1/shareA")
	srv.mu.Unlock()
	client := &taildriveWebDAVClient{
		httpClient: &http.Client{Transport: srv},
	}
	controller := &backendController{}

	invokeUpload := func(reqID int64, localPath, remoteName string) taildriveTransferSnapshot {
		t.Helper()
		payload, err := json.Marshal(taildriveTransferRequest{
			RequestID:  reqID,
			RemotePath: "/flypigj.github/pc1/shareA/" + remoteName,
			LocalRoot:  stagingRoot,
			LocalPath:  localPath,
			Overwrite:  true,
		})
		if err != nil {
			t.Fatalf("marshal upload request: %v", err)
		}
		raw := controller.taildriveUploadWithClient(string(payload), client)
		var snap taildriveTransferSnapshot
		if err := json.Unmarshal([]byte(raw), &snap); err != nil {
			t.Fatalf("unmarshal snapshot %q: %v", raw, err)
		}
		return snap
	}

	// 1. Symlink pointing outside staging root fails immediately with file_unavailable and zero HTTP PUTs.
	symSnap := invokeUpload(101, symlinkPath, "escaped.txt")
	if symSnap.State != "failed" || symSnap.Reason != "file_unavailable" {
		t.Fatalf("symlink upload = %+v; want failed/file_unavailable", symSnap)
	}
	if len(srv.log) != 0 {
		t.Fatalf("symlink upload sent HTTP traffic: %v", srv.log)
	}

	// 2. Directory fails immediately with file_unavailable and zero HTTP PUTs.
	dirSnap := invokeUpload(102, subDirPath, "dir.txt")
	if dirSnap.State != "failed" || dirSnap.Reason != "file_unavailable" {
		t.Fatalf("directory upload = %+v; want failed/file_unavailable", dirSnap)
	}

	// 3. FIFO named pipe fails immediately without hanging (O_NONBLOCK) and zero HTTP PUTs.
	fifoDone := make(chan taildriveTransferSnapshot, 1)
	go func() {
		fifoDone <- invokeUpload(103, fifoPath, "fifo.txt")
	}()
	select {
	case fifoSnap := <-fifoDone:
		if fifoSnap.State != "failed" || fifoSnap.Reason != "file_unavailable" {
			t.Fatalf("fifo upload = %+v; want failed/file_unavailable", fifoSnap)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("fifo upload blocked instead of failing fast with O_NONBLOCK")
	}
	if len(srv.log) != 0 {
		t.Fatalf("non-regular uploads sent HTTP traffic: %v", srv.log)
	}

	// 4. Regular file succeeds and io.LimitReader caps uploaded stream at initial info.Size() even if appended mid-upload.
	regularPath := filepath.Join(stagingRoot, "report.txt")
	initialPayload := []byte("0123456789ABCDEF")
	if err := os.WriteFile(regularPath, initialPayload, 0o600); err != nil {
		t.Fatalf("write regular file: %v", err)
	}
	srv.onPutBeforeRead = func(req *http.Request) {
		if req.ContentLength != int64(len(initialPayload)) {
			t.Errorf("ContentLength = %d; want %d", req.ContentLength, len(initialPayload))
		}
		f, openErr := os.OpenFile(regularPath, os.O_WRONLY|os.O_APPEND, 0o600)
		if openErr == nil {
			_, _ = f.Write([]byte("-APPENDED-AFTER-OPEN"))
			_ = f.Close()
		}
	}
	regSnap := invokeUpload(104, regularPath, "report.txt")
	if regSnap.State != "completed" || regSnap.Reason != "" || regSnap.Bytes != int64(len(initialPayload)) {
		t.Fatalf("regular upload = %+v; want completed with %d bytes", regSnap, len(initialPayload))
	}
	uploadedNode := srv.nodes["/flypigj.github/pc1/shareA/report.txt"]
	if uploadedNode == nil || !bytes.Equal(uploadedNode.body, initialPayload) {
		t.Fatalf("uploaded body = %q; want exact initial %q", uploadedNode.body, initialPayload)
	}
}

func TestTaildriveDownloadAndCrossShareCopyEnforceStreamBounds(t *testing.T) {
	savedMax := maxTaildriveTransferBytes
	maxTaildriveTransferBytes = 1024
	defer func() {
		maxTaildriveTransferBytes = savedMax
	}()

	srv := newFakeWebDAVServer()
	srv.mu.Lock()
	srv.ensureDir("/flypigj.github/pc1/shareA")
	srv.ensureDir("/flypigj.github/pc1/shareB")
	srv.nodes["/flypigj.github/pc1/shareA/chunked_ok.bin"] = &fakeWebDAVNode{
		body:       bytes.Repeat([]byte("a"), 512),
		chunked:    true,
		modifiedAt: time.Unix(1700000100, 0).UTC(),
	}
	srv.nodes["/flypigj.github/pc1/shareA/chunked_too_big.bin"] = &fakeWebDAVNode{
		body:       bytes.Repeat([]byte("b"), 2048),
		chunked:    true,
		modifiedAt: time.Unix(1700000100, 0).UTC(),
	}
	srv.nodes["/flypigj.github/pc1/shareA/known_too_big.bin"] = &fakeWebDAVNode{
		body:       bytes.Repeat([]byte("c"), 2048),
		modifiedAt: time.Unix(1700000100, 0).UTC(),
	}
	declared256 := int64(256)
	srv.nodes["/flypigj.github/pc1/shareA/dishonest_len.bin"] = &fakeWebDAVNode{
		body:                  bytes.Repeat([]byte("d"), 512),
		overrideContentLength: &declared256,
		modifiedAt:            time.Unix(1700000100, 0).UTC(),
	}
	srv.mu.Unlock()

	client := &taildriveWebDAVClient{
		httpClient: &http.Client{Transport: srv},
	}
	controller := &backendController{}
	stagingRoot := filepath.Join(t.TempDir(), "downloads")
	if err := os.MkdirAll(stagingRoot, 0o700); err != nil {
		t.Fatalf("mkdir staging: %v", err)
	}

	invokeDownload := func(reqID int64, remoteName, localName string) (taildriveTransferSnapshot, string) {
		t.Helper()
		localPath := filepath.Join(stagingRoot, localName)
		payload, err := json.Marshal(taildriveTransferRequest{
			RequestID:  reqID,
			RemotePath: "/flypigj.github/pc1/shareA/" + remoteName,
			LocalRoot:  stagingRoot,
			LocalPath:  localPath,
		})
		if err != nil {
			t.Fatalf("marshal download request: %v", err)
		}
		raw := controller.taildriveDownloadWithClient(string(payload), true, client)
		var snap taildriveTransferSnapshot
		if err := json.Unmarshal([]byte(raw), &snap); err != nil {
			t.Fatalf("unmarshal snapshot %q: %v", raw, err)
		}
		return snap, localPath
	}

	// 1. Chunked response within maxTaildriveTransferBytes succeeds cleanly.
	okSnap, okPath := invokeDownload(201, "chunked_ok.bin", "chunked_ok.bin")
	if okSnap.State != "completed" || okSnap.Bytes != 512 {
		t.Fatalf("chunked_ok download = %+v; want completed/512", okSnap)
	}
	if _, err := os.Lstat(okPath + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".part file remained after completed download: %v", err)
	}

	// 2. Chunked response exceeding maxTaildriveTransferBytes aborts and cleans up .part.
	chunkOverflowSnap, chunkOverflowPath := invokeDownload(202, "chunked_too_big.bin", "chunked_too_big.bin")
	if chunkOverflowSnap.State != "failed" || chunkOverflowSnap.Reason != "no_space" {
		t.Fatalf("chunked_too_big download = %+v; want failed/no_space", chunkOverflowSnap)
	}
	if _, err := os.Lstat(chunkOverflowPath + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".part file leaked after chunked overflow: %v", err)
	}
	if _, err := os.Lstat(chunkOverflowPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("incomplete destination file created after chunked overflow: %v", err)
	}

	// 3. Known Content-Length exceeding maxTaildriveTransferBytes fails before .part creation.
	knownOverflowSnap, knownOverflowPath := invokeDownload(203, "known_too_big.bin", "known_too_big.bin")
	if knownOverflowSnap.State != "failed" || knownOverflowSnap.Reason != "no_space" {
		t.Fatalf("known_too_big download = %+v; want failed/no_space", knownOverflowSnap)
	}
	if _, err := os.Lstat(knownOverflowPath + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".part file leaked on known-length overflow: %v", err)
	}

	// 4. Server sending more bytes than declared Content-Length fails with network_interrupted and cleans up .part.
	dishonestSnap, dishonestPath := invokeDownload(204, "dishonest_len.bin", "dishonest_len.bin")
	if dishonestSnap.State != "failed" || dishonestSnap.Reason != "network_interrupted" {
		t.Fatalf("dishonest_len download = %+v; want failed/network_interrupted", dishonestSnap)
	}
	if _, err := os.Lstat(dishonestPath + ".part"); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf(".part file leaked on Content-Length overflow: %v", err)
	}

	// 5. Cross-share copy exceeding maxTaildriveTransferBytes fails for both PROPFIND-sized and chunked streams.
	for _, tc := range []struct {
		src string
		dst string
	}{
		{src: "/flypigj.github/pc1/shareA/known_too_big.bin", dst: "/flypigj.github/pc1/shareB/known_copy.bin"},
		{src: "/flypigj.github/pc1/shareA/chunked_too_big.bin", dst: "/flypigj.github/pc1/shareB/chunked_copy.bin"},
	} {
		err := client.mutate(context.Background(), taildriveMutationRequest{
			Operation: "copy",
			Path:      tc.src,
			NewPath:   tc.dst,
		})
		if !errors.Is(err, errTaildriveTransferTooLarge) || classifyTaildriveError(err) != "no_space" {
			t.Fatalf("cross-share copy(%s) err = %v (classified %q), want errTaildriveTransferTooLarge/no_space",
				tc.src, err, classifyTaildriveError(err))
		}
		if srv.nodes[tc.dst] != nil {
			t.Fatalf("oversized cross-share copy committed truncated destination %s", tc.dst)
		}
	}
}
