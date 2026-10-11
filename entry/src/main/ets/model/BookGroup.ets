/** 书籍分组（纯数据）。一本书最多属于一个分组。 */
export class BookGroup {
  id: number = 0;
  name: string = '';
  /** 越小越靠前 */
  sortOrder: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  deleted: number = 0;

  /** 分组 + 该组书籍数，供分组管理页显示 */
  bookCount: number = 0;
}
