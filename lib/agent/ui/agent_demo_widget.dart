import 'package:flutter/material.dart';
import '../core/agent_core.dart';
import '../models/agent_output.dart';

/// Demo UI widget for agent functionality
/// Provides controls and displays for testing agent features
class AgentDemoWidget extends StatefulWidget {
  final AgentCore? agentCore;
  
  const AgentDemoWidget({
    super.key,
    this.agentCore,
  });

  @override
  State<AgentDemoWidget> createState() => _AgentDemoWidgetState();
}

class _AgentDemoWidgetState extends State<AgentDemoWidget> {
  bool _isAgentEnabled = false;
  List<AgentOutput> _recentOutputs = [];
  Map<String, dynamic>? _agentStatus;
  
  @override
  void initState() {
    super.initState();
    _updateStatus();
  }

  void _updateStatus() {
    if (widget.agentCore != null) {
      setState(() {
        _agentStatus = widget.agentCore!.status;
        _recentOutputs = widget.agentCore!.getRecentOutputs(limit: 10);
        _isAgentEnabled = _agentStatus?['isEnabled'] ?? false;
      });
    }
  }

  Future<void> _toggleAgent() async {
    if (widget.agentCore == null) return;
    
    if (_isAgentEnabled) {
      await widget.agentCore!.disable();
    } else {
      // Note: In a real implementation, you'd need to provide the actual streams
      // For demo purposes, we show the toggle but note that streams are needed
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Agent requires active audio/photo streams to enable'),
          duration: Duration(seconds: 3),
        ),
      );
    }
    
    _updateStatus();
  }

  void _clearOutputs() {
    widget.agentCore?.clearOutputs();
    _updateStatus();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.agentCore == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16.0),
          child: Column(
            children: [
              Icon(Icons.android, color: Colors.grey, size: 48),
              SizedBox(height: 8),
              Text(
                'Agent Not Available',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.grey,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Agent system is not initialized',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildControls(),
            const SizedBox(height: 16),
            _buildStatus(),
            const SizedBox(height: 16),
            _buildRecentOutputs(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Icon(
          Icons.android,
          color: _isAgentEnabled ? Colors.green : Colors.grey,
          size: 32,
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '🤖 Local Agent System',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              'On-device ASR, OCR, and LLM processing',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey,
              ),
            ),
          ],
        ),
        const Spacer(),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _isAgentEnabled ? Colors.green.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isAgentEnabled ? Colors.green : Colors.grey,
              width: 1,
            ),
          ),
          child: Text(
            _isAgentEnabled ? 'ACTIVE' : 'INACTIVE',
            style: TextStyle(
              color: _isAgentEnabled ? Colors.green : Colors.grey,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _toggleAgent,
                icon: Icon(_isAgentEnabled ? Icons.stop : Icons.play_arrow),
                label: Text(_isAgentEnabled ? 'Disable Agent' : 'Enable Agent'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isAgentEnabled 
                      ? Colors.red.withValues(alpha: 0.1) 
                      : Colors.green.withValues(alpha: 0.1),
                ),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: _clearOutputs,
              icon: const Icon(Icons.clear),
              label: const Text('Clear'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange.withValues(alpha: 0.1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _updateStatus,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh Status'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatus() {
    if (_agentStatus == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12.0),
          child: Text('No status available'),
        ),
      );
    }

    final services = _agentStatus!['services'] as Map<String, dynamic>? ?? {};
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '📊 Agent Status',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildStatusRow('Enabled', _agentStatus!['isEnabled'] ?? false),
            _buildStatusRow('Processing', _agentStatus!['isProcessing'] ?? false),
            const SizedBox(height: 8),
            Text('Total Outputs: ${_agentStatus!['totalOutputs'] ?? 0}'),
            Text('ASR Outputs: ${_agentStatus!['asrOutputs'] ?? 0}'),
            Text('OCR Outputs: ${_agentStatus!['ocrOutputs'] ?? 0}'),
            Text('LLM Calls: ${_agentStatus!['llmCalls'] ?? 0}'),
            const SizedBox(height: 8),
            const Text('Services:', style: TextStyle(fontWeight: FontWeight.bold)),
            _buildStatusRow('ASR', services['asr'] ?? false),
            _buildStatusRow('OCR', services['ocr'] ?? false),
            _buildStatusRow('LLM', services['llm'] ?? false),
            _buildStatusRow('Vector DB', services['vector'] ?? false),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusRow(String label, bool isReady) {
    return Row(
      children: [
        Icon(
          isReady ? Icons.check_circle : Icons.cancel,
          color: isReady ? Colors.green : Colors.red,
          size: 16,
        ),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }

  Widget _buildRecentOutputs() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '📝 Recent Agent Outputs',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              '${_recentOutputs.length} items',
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          height: 200,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: _recentOutputs.isEmpty
              ? const Center(
                  child: Text(
                    'No agent outputs yet\n\nEnable agent and use Frame to see ASR/OCR results',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: _recentOutputs.length,
                  itemBuilder: (context, index) {
                    final output = _recentOutputs[index];
                    return _buildOutputItem(output);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildOutputItem(AgentOutput output) {
    final typeIcon = _getTypeIcon(output.type);
    final timeStr = '${output.timestamp.hour.toString().padLeft(2, '0')}:'
                   '${output.timestamp.minute.toString().padLeft(2, '0')}:'
                   '${output.timestamp.second.toString().padLeft(2, '0')}';
    
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _getTypeColor(output.type).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _getTypeColor(output.type).withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(typeIcon, size: 16, color: _getTypeColor(output.type)),
              const SizedBox(width: 4),
              Text(
                output.type.name.toUpperCase(),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: _getTypeColor(output.type),
                ),
              ),
              const Spacer(),
              Text(
                timeStr,
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            output.content,
            style: const TextStyle(fontSize: 13),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                'Confidence: ${(output.confidence * 100).toStringAsFixed(0)}%',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              ),
              const SizedBox(width: 8),
              if (output.hasAssociatedImages)
                Text(
                  '${output.associatedImageCount} images',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _getTypeIcon(AgentOutputType type) {
    switch (type) {
      case AgentOutputType.asr:
        return Icons.mic;
      case AgentOutputType.ocr:
        return Icons.text_fields;
      case AgentOutputType.llm:
        return Icons.psychology;
      case AgentOutputType.toolCall:
        return Icons.build;
    }
  }

  Color _getTypeColor(AgentOutputType type) {
    switch (type) {
      case AgentOutputType.asr:
        return Colors.blue;
      case AgentOutputType.ocr:
        return Colors.green;
      case AgentOutputType.llm:
        return Colors.purple;
      case AgentOutputType.toolCall:
        return Colors.orange;
    }
  }
}