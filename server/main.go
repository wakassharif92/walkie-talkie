package main

import (
	"log"
	"net/http"
	"strings"
	"sync"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

var hub = struct {
	sync.Mutex
	clients map[*websocket.Conn]bool
	users   map[*websocket.Conn]string
	mic     *websocket.Conn
	targets map[*websocket.Conn]map[string]bool
}{
	clients: make(map[*websocket.Conn]bool),
	users:   make(map[*websocket.Conn]string),
	targets: make(map[*websocket.Conn]map[string]bool),
}

func main() {
	http.HandleFunc("/ws", handleWebSocket)
	log.Println("WebSocket server listening on ws://localhost:8080/ws")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func handleWebSocket(w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("upgrade:", err)
		return
	}
	defer conn.Close()

	hub.Lock()
	hub.clients[conn] = true
	hub.Unlock()

	log.Println("client connected")
	defer removeClient(conn)

	for {
		messageType, data, err := conn.ReadMessage()
		if err != nil {
			return
		}

		switch messageType {
		case websocket.TextMessage:
			handleText(conn, string(data))
		case websocket.BinaryMessage:
			broadcastAudio(conn, data)
		}
	}
}

func handleText(conn *websocket.Conn, message string) {
	log.Println("text:", message)

	switch message {
	case "REQUEST_MIC":
		handleMicRequest(conn, nil)
	case "RELEASE_MIC":
		hub.Lock()
		if hub.mic == conn {
			hub.mic = nil
			delete(hub.targets, conn)
			recipients := otherClientsLocked(conn)
			hub.Unlock()
			writeText(conn, "MIC_RELEASED")
			broadcastText(recipients, "REMOTE_TALKING_STOPPED")
			return
		}
		hub.Unlock()
		writeText(conn, "MIC_RELEASED")
	default:
		if strings.HasPrefix(message, "HELLO|") {
			hub.Lock()
			hub.users[conn] = strings.TrimPrefix(message, "HELLO|")
			hub.Unlock()
			return
		}
		if strings.HasPrefix(message, "REQUEST_MIC|") {
			rawTargets := strings.TrimPrefix(message, "REQUEST_MIC|")
			targets := map[string]bool{}
			for _, target := range strings.Split(rawTargets, ",") {
				target = strings.TrimSpace(target)
				if target != "" {
					targets[target] = true
				}
			}
			handleMicRequest(conn, targets)
			return
		}
	}
}

func handleMicRequest(conn *websocket.Conn, targets map[string]bool) {
	hub.Lock()
	if hub.mic == nil || hub.mic == conn {
		hub.mic = conn
		hub.targets[conn] = targets
		recipients := targetClientsLocked(conn, targets)
		hub.Unlock()
		writeText(conn, "MIC_GRANTED")
		broadcastText(recipients, "REMOTE_TALKING_STARTED")
		return
	}
	hub.Unlock()
	writeText(conn, "MIC_DENIED")
}

func broadcastAudio(sender *websocket.Conn, data []byte) {
	hub.Lock()
	if hub.mic != sender {
		hub.Unlock()
		return
	}

	recipients := targetClientsLocked(sender, hub.targets[sender])
	hub.Unlock()

	log.Printf("audio chunk: %d bytes", len(data))
	for _, client := range recipients {
		if err := client.WriteMessage(websocket.BinaryMessage, data); err != nil {
			log.Println("broadcast:", err)
			removeClient(client)
		}
	}
}

func writeText(conn *websocket.Conn, message string) {
	if err := conn.WriteMessage(websocket.TextMessage, []byte(message)); err != nil {
		log.Println("write:", err)
		removeClient(conn)
	}
}

func broadcastText(recipients []*websocket.Conn, message string) {
	for _, client := range recipients {
		writeText(client, message)
	}
}

func otherClientsLocked(sender *websocket.Conn) []*websocket.Conn {
	recipients := make([]*websocket.Conn, 0, len(hub.clients))
	for client := range hub.clients {
		if client != sender {
			recipients = append(recipients, client)
		}
	}
	return recipients
}

func targetClientsLocked(sender *websocket.Conn, targets map[string]bool) []*websocket.Conn {
	if len(targets) == 0 {
		return otherClientsLocked(sender)
	}

	recipients := make([]*websocket.Conn, 0, len(hub.clients))
	for client := range hub.clients {
		if client == sender {
			continue
		}
		if targets[hub.users[client]] {
			recipients = append(recipients, client)
		}
	}
	return recipients
}

func removeClient(conn *websocket.Conn) {
	var recipients []*websocket.Conn

	hub.Lock()
	delete(hub.clients, conn)
	delete(hub.users, conn)
	delete(hub.targets, conn)
	if hub.mic == conn {
		hub.mic = nil
		recipients = otherClientsLocked(conn)
	}
	hub.Unlock()

	if recipients != nil {
		broadcastText(recipients, "REMOTE_TALKING_STOPPED")
	}

	log.Println("client disconnected")
}
