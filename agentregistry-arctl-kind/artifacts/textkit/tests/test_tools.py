"""Tests for textkit MCP server tools."""

import sys
from pathlib import Path

# Add src to Python path
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from core.server import DynamicMCPServer  # noqa: E402


class TestToolLoading:
    """Test that all tools can be loaded successfully."""

    def test_server_initialization(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        assert server is not None
        assert server.name == "Test Server"

    def test_expected_tools_loaded(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        assert "word_count" in server.loaded_tools
        assert "extract_links" in server.loaded_tools

    def test_tool_functions_callable(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        tools = server.get_tools_sync()
        for tool_name, tool in tools.items():
            assert hasattr(tool, "fn"), f"Tool {tool_name} has no fn attribute"
            assert callable(tool.fn), f"Tool {tool_name} is not callable"


class TestWordCount:
    """Test the word_count tool."""

    def test_counts(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        fn = server.get_tools_sync()["word_count"].fn
        result = fn("Hello world. This is a test!")
        assert result["words"] == 6
        assert result["sentences"] == 2
        assert result["characters"] == len("Hello world. This is a test!")

    def test_empty(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        fn = server.get_tools_sync()["word_count"].fn
        assert fn("")["words"] == 0


class TestExtractLinks:
    """Test the extract_links tool."""

    def test_dedupes_in_order(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        fn = server.get_tools_sync()["extract_links"].fn
        text = "see https://a.example and https://b.example, also https://a.example again"
        result = fn(text)
        assert result["count"] == 2
        assert result["links"] == ["https://a.example", "https://b.example"]

    def test_no_links(self) -> None:
        server = DynamicMCPServer(name="Test Server", tools_dir="src/tools")
        server.load_tools()
        fn = server.get_tools_sync()["extract_links"].fn
        assert fn("no links here")["count"] == 0
