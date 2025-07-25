import 'package:objectbox/objectbox.dart';

@Entity()
class Document {
  @Id()
  int id = 0;
  
  String textContent;
  
  @Property(type: PropertyType.floatVector)
  List<double>? embedding;
  
  @Property(type: PropertyType.date)
  DateTime? createdAt;
  
  String? metadata;

  Document({
    this.id = 0,
    this.textContent = '',
    this.embedding,
    this.createdAt,
    this.metadata,
  });

  @override
  String toString() {
    return 'Document{id: $id, textContent: $textContent, embedding: ${embedding?.length ?? 0} dims, createdAt: $createdAt}';
  }
}